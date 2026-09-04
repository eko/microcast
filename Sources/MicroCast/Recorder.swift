import Foundation
import os

/// Writes one of the encoded streams to disk while it is being broadcast.
final class Recorder {
	let url: URL
	private let task: Task<Void, Never>
	private let written: OSAllocatedUnfairLock<Int64>

	var bytesWritten: Int64 { written.withLock { $0 } }

	init(stream: AsyncStream<Data>, url: URL) throws {
		self.url = url
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
		let handle = try FileHandle(forWritingTo: url)
		let counter = OSAllocatedUnfairLock(initialState: Int64(0))
		written = counter
		task = Task.detached {
			for await chunk in stream {
				guard (try? handle.write(contentsOf: chunk)) != nil else { break }
				counter.withLock { $0 += Int64(chunk.count) }
			}
			try? handle.close()
		}
	}

	func stop() {
		task.cancel()
	}
}
