import Foundation

/// Fans a live byte stream out to any number of HTTP clients without ever blocking the producer.
/// A client that cannot keep up loses the oldest chunks instead of accumulating delay.
final class Broadcaster {
	private let lock = NSLock()
	private var clients: [UUID: AsyncStream<Data>.Continuation] = [:]
	private var preambleData: Data?

	/// Bytes every new client receives before live data, e.g. a FLAC stream header.
	var preamble: Data? {
		get { lock.withLock { preambleData } }
		set { lock.withLock { preambleData = newValue } }
	}

	var clientCount: Int {
		lock.withLock { clients.count }
	}

	func subscribe() -> AsyncStream<Data> {
		let id = UUID()
		return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
			continuation.onTermination = { [weak self] _ in self?.remove(id) }
			lock.withLock {
				if let preambleData { continuation.yield(preambleData) }
				clients[id] = continuation
			}
		}
	}

	func publish(_ chunk: Data) {
		lock.withLock {
			for continuation in clients.values { continuation.yield(chunk) }
		}
	}

	func closeAll() {
		let open: [AsyncStream<Data>.Continuation] = lock.withLock {
			let all = Array(clients.values)
			clients.removeAll()
			return all
		}
		open.forEach { $0.finish() }
	}

	private func remove(_ id: UUID) {
		lock.withLock { _ = clients.removeValue(forKey: id) }
	}
}
