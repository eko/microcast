import XCTest
@testable import MicroCast

final class PlaylistTests: XCTestCase {
	func testTargetsFollowPartAndSegmentDurations() {
		let playlist = LivePlaylist(partDuration: 0.334, segmentDuration: 2, title: "Show")
		XCTAssertEqual(playlist.partTarget, 0.356, accuracy: 0.0005)
		XCTAssertEqual(playlist.partsPerSegment, 6)
		XCTAssertEqual(playlist.targetDuration, 3)
	}

	func testRenderListsPartsSegmentsAndPreloadHint() {
		let playlist = LivePlaylist(partDuration: 0.334, segmentDuration: 2, title: "Show")
		playlist.setInitialization(Data([0x01]))
		for index in 0..<7 { playlist.add(part: Data([UInt8(index)]), duration: 0.334) }
		let text = playlist.render()
		XCTAssertTrue(text.hasPrefix("#EXTM3U\n"))
		XCTAssertTrue(text.contains("#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=1.068"))
		XCTAssertTrue(text.contains("#EXT-X-PART-INF:PART-TARGET=0.356"))
		XCTAssertTrue(text.contains("#EXT-X-MEDIA-SEQUENCE:0"))
		XCTAssertTrue(text.contains("#EXT-X-PART:DURATION=0.334,URI=\"seg0.5.m4s\",INDEPENDENT=YES"))
		XCTAssertTrue(text.contains("#EXTINF:2.004,Show\nseg0.m4s"))
		XCTAssertTrue(text.contains("#EXT-X-PART:DURATION=0.334,URI=\"seg1.0.m4s\""))
		XCTAssertTrue(text.hasSuffix("#EXT-X-PRELOAD-HINT:TYPE=PART,URI=\"seg1.1.m4s\"\n"))
		XCTAssertEqual(playlist.segment(sequence: 0)?.count, 6)
		XCTAssertNil(playlist.segment(sequence: 1), "an incomplete segment is not served whole")
		XCTAssertEqual(playlist.part(sequence: 1, index: 0), Data([6]))
	}

	func testWindowDropsOldSegments() {
		let playlist = LivePlaylist(partDuration: 1, segmentDuration: 1, title: "")
		for _ in 0..<20 { playlist.add(part: Data(), duration: 1) }
		XCTAssertTrue(playlist.render().contains("#EXT-X-MEDIA-SEQUENCE:13"))
		XCTAssertNil(playlist.segment(sequence: 0))
	}

	func testWaitReturnsImmediatelyWhenSatisfied() async {
		let playlist = LivePlaylist(partDuration: 1, segmentDuration: 2, title: "")
		playlist.add(part: Data(), duration: 1)
		let start = Date()
		await playlist.wait(forSequence: 0, part: 0, timeout: 5)
		XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
	}

	func testWaitResumesWhenThePartArrives() async {
		let playlist = LivePlaylist(partDuration: 1, segmentDuration: 2, title: "")
		playlist.add(part: Data(), duration: 1)
		Task.detached {
			try? await Task.sleep(for: .milliseconds(150))
			playlist.add(part: Data(), duration: 1)
		}
		let start = Date()
		await playlist.wait(forSequence: 0, part: 1, timeout: 5)
		let elapsed = Date().timeIntervalSince(start)
		XCTAssertGreaterThan(elapsed, 0.1)
		XCTAssertLessThan(elapsed, 2)
	}

	func testWaitTimesOut() async {
		let playlist = LivePlaylist(partDuration: 1, segmentDuration: 2, title: "")
		playlist.add(part: Data(), duration: 1)
		let start = Date()
		await playlist.wait(forSequence: 1, part: 0, timeout: 0.2)
		let elapsed = Date().timeIntervalSince(start)
		XCTAssertGreaterThan(elapsed, 0.15)
		XCTAssertLessThan(elapsed, 2)
	}

	func testImpossibleRequestsDoNotWait() async {
		let playlist = LivePlaylist(partDuration: 1, segmentDuration: 1, title: "")
		playlist.add(part: Data(), duration: 1) // segment 0 complete
		let start = Date()
		await playlist.wait(forSequence: 0, part: 5, timeout: 5) // beyond the last part of a complete segment
		await playlist.wait(forSequence: 40, part: nil, timeout: 5) // far ahead
		XCTAssertLessThan(Date().timeIntervalSince(start), 1)
	}
}
