import AVFoundation
import CoreMedia
import Foundation
import os

enum JingleError: LocalizedError {
	case decode(String)

	var errorDescription: String? {
		switch self {
		case .decode(let name): "could not decode \(name)"
		}
	}
}

/// A folder of short audio files, one of which plays over the ducked music at track changes.
struct JingleBank {
	static let extensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "caf"]
	static var defaultFolder: URL {
		FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/MicroCast/Jingles")
	}

	let folder: URL

	var files: [URL] {
		((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
			.filter { Self.extensions.contains($0.pathExtension.lowercased()) }
			.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
	}

	/// A random file, avoiding an immediate repeat when there is a choice.
	func pick(avoiding last: URL?) -> URL? {
		let candidates = files
		let lastPath = last?.resolvingSymlinksInPath().path
		let fresh = candidates.filter { $0.resolvingSymlinksInPath().path != lastPath }
		return (fresh.isEmpty ? candidates : fresh).randomElement()
	}

	/// The file as interleaved 48 kHz stereo samples.
	static func decode(_ url: URL) throws -> [Float] {
		let file = try AVAudioFile(forReading: url)
		let source = file.processingFormat
		guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(max(1, file.length))) else { throw JingleError.decode(url.lastPathComponent) }
		try file.read(into: buffer)
		var samplesBuffer = buffer
		if source.sampleRate != Double(AudioCapture.sampleRate) {
			guard let target = AVAudioFormat(standardFormatWithSampleRate: Double(AudioCapture.sampleRate), channels: source.channelCount),
				let converter = AVAudioConverter(from: source, to: target),
				let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / source.sampleRate) + 64) else {
				throw JingleError.decode(url.lastPathComponent)
			}
			var fed = false
			var error: NSError?
			converter.convert(to: converted, error: &error) { _, status in
				if fed { status.pointee = .endOfStream; return nil }
				fed = true
				status.pointee = .haveData
				return buffer
			}
			if let error { throw error }
			samplesBuffer = converted
		}
		guard let channels = samplesBuffer.floatChannelData else { throw JingleError.decode(url.lastPathComponent) }
		let frames = Int(samplesBuffer.frameLength)
		let stereo = samplesBuffer.format.channelCount >= 2
		var samples = [Float](repeating: 0, count: frames * 2)
		for frame in 0..<frames {
			samples[frame * 2] = channels[0][frame]
			samples[frame * 2 + 1] = stereo ? channels[1][frame] : channels[0][frame]
		}
		return samples
	}
}

/// Ducks the programme under a jingle: fade down, jingle on top, fade back. Pure sample maths, unit tested.
struct DuckingMixer {
	var duckGain: Float = 0.25
	var jingleGain: Float = 1
	var fadeDownFrames = 24_000
	var fadeUpFrames = 48_000

	private enum Phase {
		case idle
		case fadingDown
		case playing(Int)
		case fadingUp
	}

	private var phase = Phase.idle
	private var gain: Float = 1
	private var jingle: [Float] = []

	init(duckGain: Float = 0.25, jingleGain: Float = 1, fadeDownFrames: Int = 24_000, fadeUpFrames: Int = 48_000) {
		self.duckGain = duckGain
		self.jingleGain = jingleGain
		self.fadeDownFrames = fadeDownFrames
		self.fadeUpFrames = fadeUpFrames
	}

	var isActive: Bool {
		if case .idle = phase { return false }
		return true
	}

	mutating func start(_ samples: [Float]) {
		guard !samples.isEmpty else { return }
		jingle = samples
		if case .idle = phase { phase = .fadingDown }
		if case .playing = phase { phase = .playing(0) }
	}

	/// Interleaved stereo 16-bit frames, processed in place.
	mutating func process(_ samples: UnsafeMutableBufferPointer<Int16>) {
		guard isActive else { return }
		let downStep = (1 - duckGain) / Float(max(1, fadeDownFrames))
		let upStep = (1 - duckGain) / Float(max(1, fadeUpFrames))
		var index = 0
		while index + 1 < samples.count {
			var addLeft: Float = 0, addRight: Float = 0
			switch phase {
			case .idle:
				return
			case .fadingDown:
				gain -= downStep
				if gain <= duckGain { gain = duckGain; phase = .playing(0) }
			case .playing(let position):
				if position + 1 < jingle.count {
					addLeft = jingle[position] * jingleGain
					addRight = jingle[position + 1] * jingleGain
					phase = .playing(position + 2)
				} else {
					phase = .fadingUp
				}
			case .fadingUp:
				gain += upStep
				if gain >= 1 { gain = 1; phase = .idle; jingle = [] }
			}
			samples[index] = Self.clamp(Float(samples[index]) * gain + addLeft * 32767)
			samples[index + 1] = Self.clamp(Float(samples[index + 1]) * gain + addRight * 32767)
			index += 2
		}
	}

	private static func clamp(_ value: Float) -> Int16 {
		Int16(max(-32768, min(32767, value)))
	}
}

/// The stage between the capture and the encoders: applies jingles and builds the sample buffers HLS needs.
final class AudioMixer {
	var output: (CMSampleBuffer, Data) -> Void = { _, _ in }
	private let lock = NSLock()
	private var mixer = DuckingMixer()
	private var pendingJingle: [Float]?
	private var formatDescription: CMAudioFormatDescription?
	private var framesDelivered: Int64 = 0
	private let logger = Logger(subsystem: "local.microcast", category: "mixer")

	init() {
		var asbd = AudioStreamBasicDescription(
			mSampleRate: Double(AudioCapture.sampleRate), mFormatID: kAudioFormatLinearPCM,
			mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
			mBytesPerPacket: UInt32(AudioCapture.bytesPerFrame), mFramesPerPacket: 1, mBytesPerFrame: UInt32(AudioCapture.bytesPerFrame),
			mChannelsPerFrame: UInt32(AudioCapture.channels), mBitsPerChannel: 16, mReserved: 0
		)
		CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription)
	}

	func configure(duckDecibels: Double, jingleVolume: Double) {
		lock.withLock {
			mixer.duckGain = Float(pow(10, duckDecibels / 20))
			mixer.jingleGain = Float(jingleVolume)
		}
	}

	/// Queues a jingle; it starts on the next buffer. Ignored while one is already playing.
	func play(_ samples: [Float]) -> Bool {
		lock.withLock {
			guard !mixer.isActive, pendingJingle == nil else { return false }
			pendingJingle = samples
			return true
		}
	}

	var isPlayingJingle: Bool { lock.withLock { mixer.isActive } }

	/// Called on the capture thread with interleaved 48 kHz stereo 16-bit PCM.
	func append(_ pcm: Data) {
		var data = pcm
		lock.withLock {
			if let pending = pendingJingle {
				mixer.start(pending)
				pendingJingle = nil
			}
			if mixer.isActive {
				data.withUnsafeMutableBytes { raw in mixer.process(raw.bindMemory(to: Int16.self)) }
			}
		}
		guard let sampleBuffer = makeSampleBuffer(data) else { return }
		output(sampleBuffer, data)
	}

	private func makeSampleBuffer(_ data: Data) -> CMSampleBuffer? {
		guard let formatDescription else { return nil }
		let frames = data.count / AudioCapture.bytesPerFrame
		var timing = CMSampleTimingInfo(
			duration: CMTime(value: 1, timescale: CMTimeScale(AudioCapture.sampleRate)),
			presentationTimeStamp: CMTime(value: framesDelivered, timescale: CMTimeScale(AudioCapture.sampleRate)),
			decodeTimeStamp: .invalid
		)
		var sampleBuffer: CMSampleBuffer?
		guard CMSampleBufferCreate(
			allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
			formatDescription: formatDescription, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
			sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer
		) == noErr, let sampleBuffer else { return nil }
		let status = data.withUnsafeBytes { raw -> OSStatus in
			var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(data.count), mData: UnsafeMutableRawPointer(mutating: raw.baseAddress)))
			return CMSampleBufferSetDataBufferFromAudioBufferList(
				sampleBuffer, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
				flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, bufferList: &bufferList
			)
		}
		guard status == noErr else { return nil }
		framesDelivered += Int64(frames)
		return sampleBuffer
	}
}

/// When to fire a jingle so it starts `lead` seconds before the end of the track, given polls every `interval`.
enum JingleScheduler {
	/// Seconds to wait before starting, or nil when the moment is still more than a poll away.
	static func delay(remaining: Double, lead: Double, interval: Double) -> Double? {
		let wait = remaining - lead
		guard wait <= interval + 0.25 else { return nil }
		return max(0, wait)
	}
}
