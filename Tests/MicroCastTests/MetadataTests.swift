import XCTest
@testable import MicroCast

final class MetadataTests: XCTestCase {
	func testRouterTitlePatternUpdatesLive() async {
		let monitor = NowPlayingMonitor()
		monitor.preview(NowPlaying(source: "Music", title: "Redbone", artist: "Gambino", album: "A", trackID: "1"))
		let router = TestRouter.make(name: "Radio", nowPlaying: monitor)
		router.setTitlePattern("%name%: %artist% - %title%")
		XCTAssertEqual(router.currentTitle(), "Radio: Gambino - Redbone")
		let first = await router.handle(TestRouter.request("/status.json")).json["streamTitle"] as? String
		XCTAssertEqual(first, "Radio: Gambino - Redbone")
		router.setTitlePattern("Now: %title%")
		XCTAssertEqual(router.currentTitle(), "Now: Redbone", "new pattern takes effect without rebuilding the router")
		let second = await router.handle(TestRouter.request("/status.json")).json["streamTitle"] as? String
		XCTAssertEqual(second, "Now: Redbone")
	}

	func testTitleTemplateFillsPlaceholders() {
		let track = NowPlaying(source: "Music", title: "Redbone", artist: "Childish Gambino", album: "Awaken", trackID: "1")
		XCTAssertEqual(TitleTemplate.render("Vincent Stream - Now playing: %artist% - %title%", name: "Vincent Stream", track: track),
					   "Vincent Stream - Now playing: Childish Gambino - Redbone")
		XCTAssertEqual(TitleTemplate.render("%name%", name: "Radio", track: track), "Radio")
		XCTAssertEqual(TitleTemplate.render("", name: "Radio", track: track), "Radio — Childish Gambino - Redbone", "empty pattern uses the default")
	}

	func testTitleTemplateFallsBackToNameWithoutATrack() {
		XCTAssertEqual(TitleTemplate.render("Now playing: %artist% - %title%", name: "Radio", track: nil), "Radio")
	}

	func testICYMetadataBlockIsPaddedToSixteenBytes() {
		let block = ICY.metadataBlock("A")
		let length = Int(block[0])
		XCTAssertEqual(block.count, 1 + length * 16)
		XCTAssertEqual(length, 1, "StreamTitle='A'; is 15 bytes → one 16-byte unit")
		XCTAssertTrue(String(decoding: block.dropFirst(), as: UTF8.self).hasPrefix("StreamTitle='A';"))
		let padded = ICY.metadataBlock("hello") // "StreamTitle='hello';" = 20 bytes → 2 units, padded
		XCTAssertEqual(padded.count, 33)
		XCTAssertEqual(padded.last, 0, "NUL padded to a 16-byte multiple")
		XCTAssertFalse(String(decoding: ICY.metadataBlock("it's a 'test'").dropFirst(), as: UTF8.self).contains("'test'"), "single quotes stripped so framing can't break")
	}

	func testShoutcastReplyOnlyForVLCStylePlayers() {
		XCTAssertTrue(ICY.needsShoutcastReply(userAgent: "VLC/3.0.23 LibVLC/3.0.23"))
		XCTAssertFalse(ICY.needsShoutcastReply(userAgent: "Mozilla/5.0 (Macintosh) Safari/605"), "browsers cannot parse ICY 200 OK")
		XCTAssertFalse(ICY.needsShoutcastReply(userAgent: "AppleCoreMedia/1.0"))
		XCTAssertFalse(ICY.needsShoutcastReply(userAgent: nil))
		XCTAssertEqual(ICY.shoutcastStatusLine, "ICY 200 OK")
	}

	func testShoutcastReplyOnlyOverPlainHTTP() async throws {
		let aac = try AACStream(bitrate: 128)
		let router = TestRouter.make(aac: [128: aac], bitrates: [128], name: "Radio")
		let vlc = ["user-agent": "VLC/3.0.23 LibVLC/3.0.23"]
		let overHTTP = await router.handle(TestRouter.request("/stream-128.aac", headers: vlc, secure: false))
		XCTAssertEqual(overHTTP.statusLine, "ICY 200 OK", "VLC over http gets the Shoutcast reply")
		XCTAssertEqual(overHTTP.headers["icy-metaint"], "16000")
		let overHTTPS = await router.handle(TestRouter.request("/stream-128.aac", headers: vlc, secure: true))
		XCTAssertNil(overHTTPS.statusLine, "over TLS VLC must get standard HTTP or it cannot open the stream")
		XCTAssertNil(overHTTPS.headers["icy-metaint"])
		let asked = await router.handle(TestRouter.request("/stream-128.aac", headers: ["icy-metadata": "1"], secure: true))
		XCTAssertNil(asked.statusLine)
		XCTAssertEqual(asked.headers["icy-metaint"], "16000", "a client that asks still gets metadata over TLS")
	}

	func testInterleaverInsertsBlocksAtBoundaries() {
		var icy = ICYInterleaver(metaint: 10)
		// 25 bytes of audio, title "T" → boundary at 10 and 20
		let out = icy.process(Data(repeating: 0x41, count: 25), title: "T")
		// [10 audio][block T][10 audio][0x00][5 audio]
		let block = ICY.metadataBlock("T")
		var expected = Data(repeating: 0x41, count: 10) + block + Data(repeating: 0x41, count: 10) + ICY.noChange + Data(repeating: 0x41, count: 5)
		XCTAssertEqual(out, expected)
	}

	func testInterleaverSpansChunksAndReactsToTitleChanges() {
		var icy = ICYInterleaver(metaint: 8)
		XCTAssertEqual(icy.process(Data(repeating: 1, count: 5), title: "A"), Data(repeating: 1, count: 5), "no boundary yet")
		let out = icy.process(Data(repeating: 1, count: 5), title: "B") // total 10 → boundary at byte 8
		// 3 bytes finish the first window, then a block with the CURRENT title, then 2 bytes
		XCTAssertEqual(out.prefix(3), Data(repeating: 1, count: 3))
		XCTAssertTrue(String(decoding: out, as: UTF8.self).contains("StreamTitle='B';"))
		XCTAssertEqual(out.suffix(2), Data(repeating: 1, count: 2))
	}
}
