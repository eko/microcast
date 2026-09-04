import Foundation

/// Raw 48 kHz stereo 16-bit PCM in 20 ms chunks: the page's ultra-low-latency mode (1.5 Mbit/s, any network that keeps up).
final class PCMStream {
	static let chunkFrames = 960
	let broadcaster = Broadcaster()
	private var pending = Data()
	private let queue = DispatchQueue(label: "local.microcast.pcm")

	func append(_ pcm: Data) {
		queue.async {
			self.pending.append(pcm)
			let chunkBytes = Self.chunkFrames * AudioCapture.bytesPerFrame
			while self.pending.count >= chunkBytes {
				self.broadcaster.publish(Data(self.pending.prefix(chunkBytes)))
				self.pending.removeFirst(chunkBytes)
			}
		}
	}
}
