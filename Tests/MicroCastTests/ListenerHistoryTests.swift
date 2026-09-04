import XCTest
@testable import MicroCast

final class ListenerHistoryTests: XCTestCase {
	func testKeepsPeakAndBoundedSamples() {
		let history = ListenerHistory(capacity: 3)
		let start = Date(timeIntervalSince1970: 1_000)
		for (index, count) in [1, 5, 2, 3].enumerated() {
			history.record(count, at: start.addingTimeInterval(Double(index) * 5))
		}
		XCTAssertEqual(history.samples.map(\.count), [5, 2, 3], "oldest sample dropped")
		XCTAssertEqual(history.peak, 5, "peak survives the drop")
		XCTAssertEqual(history.recent(seconds: 6, now: start.addingTimeInterval(15)).map(\.count), [2, 3])
		XCTAssertEqual(history.jsonRows(seconds: 100, now: start.addingTimeInterval(20)).first, [1_005, 5])
	}
}
