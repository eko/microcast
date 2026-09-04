import AVFoundation
import UniformTypeIdentifiers
import os

/// One HLS rendition: AAC at a fixed bitrate, packaged into fMP4 partial segments by AVAssetWriter.
final class HLSVariant: NSObject, AVAssetWriterDelegate {
	let bitrate: Int
	let playlist: LivePlaylist

	private let partDuration: Double
	private let queue: DispatchQueue
	private var writer: AVAssetWriter?
	private var input: AVAssetWriterInput?
	/// Buffers the encoder was not ready for yet (it needs a few hundred ms to warm up).
	private var backlog: [CMSampleBuffer] = []
	private let logger = Logger(subsystem: "local.microcast", category: "hls")

	private let title: String

	init(bitrate: Int, partDuration: Double, segmentDuration: Double, title: String) {
		self.bitrate = bitrate
		self.partDuration = partDuration
		self.title = title
		playlist = LivePlaylist(partDuration: partDuration, segmentDuration: segmentDuration, title: title)
		queue = DispatchQueue(label: "local.microcast.hls.\(bitrate)")
	}

	func append(_ sampleBuffer: CMSampleBuffer) {
		queue.async { self.write(sampleBuffer) }
	}

	func stop() {
		queue.sync {
			if let writer, writer.status == .writing {
				input?.markAsFinished()
				writer.finishWriting {}
			}
			writer = nil
			input = nil
			backlog.removeAll()
		}
	}

	private func write(_ sampleBuffer: CMSampleBuffer) {
		if writer == nil { startWriter(at: sampleBuffer.presentationTimeStamp) }
		guard let writer, let input else { return }
		if writer.status == .failed {
			logger.error("writer \(self.bitrate) failed: \(writer.error?.localizedDescription ?? "unknown")")
			self.writer = nil
			return
		}
		backlog.append(sampleBuffer)
		while input.isReadyForMoreMediaData, !backlog.isEmpty {
			input.append(backlog.removeFirst())
		}
		if backlog.count > 400 { // about two seconds: the encoder is stuck, drop rather than grow
			backlog.removeFirst(backlog.count - 400)
		}
	}

	private func startWriter(at time: CMTime) {
		let writer = AVAssetWriter(contentType: .mpeg4Movie)
		writer.outputFileTypeProfile = .mpeg4AppleHLS
		writer.preferredOutputSegmentInterval = CMTime(seconds: partDuration, preferredTimescale: CMTimeScale(AudioCapture.sampleRate))
		writer.initialSegmentStartTime = time
		writer.delegate = self
		let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
			AVFormatIDKey: kAudioFormatMPEG4AAC,
			AVSampleRateKey: AudioCapture.sampleRate,
			AVNumberOfChannelsKey: AudioCapture.channels,
			AVEncoderBitRateKey: bitrate * 1000,
		])
		input.expectsMediaDataInRealTime = true
		writer.add(input)
		guard writer.startWriting() else {
			logger.error("cannot start writer \(self.bitrate): \(writer.error?.localizedDescription ?? "unknown")")
			return
		}
		writer.startSession(atSourceTime: time)
		self.writer = writer
		self.input = input
	}

	/// AVAssetWriter drops container metadata in HLS mode, so append moov/udta/©nam (the QuickTime title)
	/// to the init segment ourselves; ffprobe and VLC read it as the stream title.
	static func addingTitle(_ title: String, to initSegment: Data) -> Data {
		var bytes = [UInt8](initSegment)
		func readSize(_ offset: Int) -> Int {
			Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
		}
		func be32(_ value: Int) -> [UInt8] { [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
		var offset = 0
		while offset + 8 <= bytes.count {
			let size = readSize(offset)
			guard size >= 8, offset + size <= bytes.count else { return initSegment }
			if bytes[offset + 4..<offset + 8].elementsEqual("moov".utf8) {
				let text = Array(title.utf8.prefix(255))
				let nam = be32(12 + text.count) + [0xA9, 0x6E, 0x61, 0x6D] + [UInt8(text.count >> 8), UInt8(text.count & 0xFF), 0, 0] + text
				let udta = be32(8 + nam.count) + Array("udta".utf8) + nam
				bytes.insert(contentsOf: udta, at: offset + size)
				bytes.replaceSubrange(offset..<offset + 4, with: be32(size + udta.count))
				return Data(bytes)
			}
			offset += size
		}
		return initSegment
	}

	func assetWriter(
		_ writer: AVAssetWriter,
		didOutputSegmentData segmentData: Data,
		segmentType: AVAssetSegmentType,
		segmentReport: AVAssetSegmentReport?
	) {
		switch segmentType {
		case .initialization:
			playlist.setInitialization(Self.addingTitle(title, to: segmentData))
		case .separable:
			let duration = segmentReport?.trackReports.first?.duration.seconds ?? partDuration
			playlist.add(part: segmentData, duration: duration)
		@unknown default:
			break
		}
	}
}
