import AVFoundation
import os

enum CaptureError: LocalizedError {
	case deviceUnavailable

	var errorDescription: String? {
		switch self {
		case .deviceUnavailable: "the audio device cannot be captured"
		}
	}
}

/// Captures one input device as 48 kHz stereo 16-bit PCM and hands every buffer to `sink`.
final class AudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
	static let sampleRate = 48_000
	static let channels = 2
	static let bytesPerFrame = 4

	private let session = AVCaptureSession()
	private let queue = DispatchQueue(label: "local.microcast.capture", qos: .userInteractive)
	private let sink: (Data) -> Void
	private let peakLevels = OSAllocatedUnfairLock(initialState: (left: Float(0), right: Float(0)))

	/// Peak of the most recent buffer per channel, 0...1.
	var levels: (left: Float, right: Float) { peakLevels.withLock { $0 } }

	init(device: AVCaptureDevice, sink: @escaping (Data) -> Void) throws {
		self.sink = sink
		super.init()
		let input = try AVCaptureDeviceInput(device: device)
		let output = AVCaptureAudioDataOutput()
		output.audioSettings = [
			AVFormatIDKey: kAudioFormatLinearPCM,
			AVSampleRateKey: Self.sampleRate,
			AVNumberOfChannelsKey: Self.channels,
			AVLinearPCMBitDepthKey: 16,
			AVLinearPCMIsFloatKey: false,
			AVLinearPCMIsBigEndianKey: false,
			AVLinearPCMIsNonInterleaved: false,
		]
		output.setSampleBufferDelegate(self, queue: queue)
		session.beginConfiguration()
		guard session.canAddInput(input), session.canAddOutput(output) else { throw CaptureError.deviceUnavailable }
		session.addInput(input)
		session.addOutput(output)
		session.commitConfiguration()
	}

	func start() {
		session.startRunning()
	}

	func stop() {
		session.stopRunning()
	}

	func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
		guard let block = sampleBuffer.dataBuffer else { return }
		let length = CMBlockBufferGetDataLength(block)
		guard length > 0 else { return }
		var pcm = Data(count: length)
		let status = pcm.withUnsafeMutableBytes { bytes in
			CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
		}
		guard status == kCMBlockBufferNoErr else { return }
		let peaks = Self.peaks(of: pcm)
		peakLevels.withLock { $0 = peaks }
		sink(pcm)
	}

	/// Interleaved stereo: even samples are left, odd samples are right.
	static func peaks(of pcm: Data) -> (left: Float, right: Float) {
		pcm.withUnsafeBytes { raw in
			var left: Int16 = 0
			var right: Int16 = 0
			let samples = raw.bindMemory(to: Int16.self)
			var index = 0
			while index + 1 < samples.count {
				left = max(left, samples[index] == .min ? .max : abs(samples[index]))
				right = max(right, samples[index + 1] == .min ? .max : abs(samples[index + 1]))
				index += 2
			}
			return (Float(left) / Float(Int16.max), Float(right) / Float(Int16.max))
		}
	}
}
