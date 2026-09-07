import Foundation

/// Fans a live byte stream out to any number of HTTP clients without ever blocking the producer.
/// A client that cannot keep up loses the oldest chunks instead of accumulating delay.
final class Broadcaster {
	private let lock = NSLock()
	private var clients: [UUID: AsyncStream<Data>.Continuation] = [:]
	private var preambleData: Data?
	private var historyData = Data()
	private var burstLimitBytes = 0

	/// Bytes every new client receives before live data, e.g. a FLAC stream header.
	var preamble: Data? {
		get { lock.withLock { preambleData } }
		set { lock.withLock { preambleData = newValue } }
	}

	var clientCount: Int {
		lock.withLock { clients.count }
	}

	/// Bytes of already-encoded audio handed to a new listener straight away ("burst on connect", as Icecast
	/// does). It fills the player's buffer immediately so playback starts at once instead of after a second of
	/// real-time audio; the listener then runs that far behind live. 0 disables it.
	var burstLimit: Int {
		get { lock.withLock { burstLimitBytes } }
		set {
			lock.withLock {
				burstLimitBytes = max(0, newValue)
				if historyData.count > burstLimitBytes {
					historyData.removeFirst(historyData.count - burstLimitBytes)
				}
			}
		}
	}

	func subscribe() -> AsyncStream<Data> {
		let id = UUID()
		return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
			continuation.onTermination = { [weak self] _ in self?.remove(id) }
			lock.withLock {
				if let preambleData { continuation.yield(preambleData) }
				if !historyData.isEmpty { continuation.yield(historyData) }
				clients[id] = continuation
			}
		}
	}

	func publish(_ chunk: Data) {
		lock.withLock {
			if burstLimitBytes > 0 {
				historyData.append(chunk)
				if historyData.count > burstLimitBytes {
					historyData.removeFirst(historyData.count - burstLimitBytes)
				}
			}
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
