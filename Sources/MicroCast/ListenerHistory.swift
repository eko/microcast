import Foundation

/// Listener counts sampled while streaming, kept for the graphs in the panel and on the page.
final class ListenerHistory: @unchecked Sendable {
	struct Sample: Identifiable, Equatable {
		let time: Date
		let count: Int
		var id: Date { time }
	}

	static let interval: TimeInterval = 5
	private let capacity: Int
	private let lock = NSLock()
	private var storage: [Sample] = []
	private var peakCount = 0

	/// Keeps `capacity` samples: one hour at the default interval.
	init(capacity: Int = 720) {
		self.capacity = capacity
	}

	var samples: [Sample] { lock.withLock { storage } }
	var peak: Int { lock.withLock { peakCount } }

	func record(_ count: Int, at time: Date = Date()) {
		lock.withLock {
			storage.append(Sample(time: time, count: count))
			if storage.count > capacity { storage.removeFirst(storage.count - capacity) }
			peakCount = max(peakCount, count)
		}
	}

	/// Samples newer than `seconds` ago.
	func recent(seconds: TimeInterval, now: Date = Date()) -> [Sample] {
		let cutoff = now.addingTimeInterval(-seconds)
		return lock.withLock { storage.filter { $0.time >= cutoff } }
	}

	/// `[[unix time, count], …]` for JSON.
	func jsonRows(seconds: TimeInterval, now: Date = Date()) -> [[Double]] {
		recent(seconds: seconds, now: now).map { [$0.time.timeIntervalSince1970.rounded(), Double($0.count)] }
	}
}
