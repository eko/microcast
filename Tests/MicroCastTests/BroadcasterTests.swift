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

	func testBurstGivesNewListenersTheRecentAudioImmediately() async {
		let broadcaster = Broadcaster()
		broadcaster.preamble = Data("HEAD".utf8)
		broadcaster.burstLimit = 6
		for byte in UInt8(1)...UInt8(10) { broadcaster.publish(Data([byte])) }
		let stream = broadcaster.subscribe()
		broadcaster.publish(Data([99]))
		broadcaster.closeAll()
		var received = Data()
		for await chunk in stream { received.append(chunk) }
		XCTAssertEqual(received.prefix(4), Data("HEAD".utf8), "header first")
		XCTAssertEqual(Array(received.dropFirst(4)), [5, 6, 7, 8, 9, 10, 99], "the last 6 bytes of history, then live audio")
	}

	func testBurstDisabledSendsOnlyLiveAudio() async {
		let broadcaster = Broadcaster()
		for byte in UInt8(1)...UInt8(5) { broadcaster.publish(Data([byte])) }
		let stream = broadcaster.subscribe()
		broadcaster.publish(Data([42]))
		broadcaster.closeAll()
		var received = Data()
		for await chunk in stream { received.append(chunk) }
		XCTAssertEqual(Array(received), [42], "no history when burst is off")
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
