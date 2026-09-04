import XCTest
@testable import MicroCast

final class BroadcasterTests: XCTestCase {
	func testDeliversPreambleThenChunksToEachSubscriber() async {
		let broadcaster = Broadcaster()
		broadcaster.preamble = Data("HEAD".utf8)
		let first = broadcaster.subscribe()
		let second = broadcaster.subscribe()
		XCTAssertEqual(broadcaster.clientCount, 2)
		broadcaster.publish(Data("one".utf8))
		broadcaster.publish(Data("two".utf8))
		broadcaster.closeAll()
		var received: [String] = []
		for await chunk in first { received.append(String(decoding: chunk, as: UTF8.self)) }
		XCTAssertEqual(received, ["HEAD", "one", "two"])
		var other: [String] = []
		for await chunk in second { other.append(String(decoding: chunk, as: UTF8.self)) }
		XCTAssertEqual(other, ["HEAD", "one", "two"])
		XCTAssertEqual(broadcaster.clientCount, 0)
	}

	func testSlowSubscriberLosesOldestChunks() async {
		let broadcaster = Broadcaster()
		let stream = broadcaster.subscribe()
		for index in 0..<100 { broadcaster.publish(Data([UInt8(index)])) }
		broadcaster.closeAll()
		var received: [UInt8] = []
		for await chunk in stream { received.append(chunk[0]) }
		XCTAssertEqual(received.count, 64, "bounded buffer keeps the newest 64")
		XCTAssertEqual(received.last, 99)
		XCTAssertEqual(received.first, 36)
	}

	func testUnsubscribesWhenTheConsumerStops() async throws {
		let broadcaster = Broadcaster()
		var stream: AsyncStream<Data>? = broadcaster.subscribe()
		XCTAssertEqual(broadcaster.clientCount, 1)
		stream = nil
		_ = stream
		try await Task.sleep(for: .milliseconds(50))
		XCTAssertEqual(broadcaster.clientCount, 0, "dropping the stream terminates the subscription")
	}
}
