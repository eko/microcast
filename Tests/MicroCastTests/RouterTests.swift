import os
import XCTest
@testable import MicroCast

final class RouterTests: XCTestCase {
	private func liveRouter(password: String = "") throws -> (Router, HLSVariant, AACStream, FLACStream, PCMStream) {
		let variant = HLSVariant(bitrate: 128, partDuration: 0.334, segmentDuration: 2, title: "T")
		variant.playlist.setInitialization(Data([0, 0, 0, 8] + Array("ftyp".utf8)))
		for index in 0..<7 { variant.playlist.add(part: Data([UInt8(index)]), duration: 0.334) }
		let aac = try AACStream(bitrate: 128)
		let flac = try FLACStream(title: "T")
		let pcm = PCMStream()
		let router = TestRouter.make(hls: [128: variant], aac: [128: aac], flac: flac, pcm: pcm, bitrates: [128], password: password, publicURL: URL(string: "https://cast.example.com/"))
		return (router, variant, aac, flac, pcm)
	}

	func testPageStatusAndManifest() async throws {
		let (router, _, _, _, _) = try liveRouter()
		let page = await router.handle(TestRouter.request("/"))
		XCTAssertEqual(page.status, 200)
		XCTAssertTrue(page.contentType.hasPrefix("text/html"))
		let status = await router.handle(TestRouter.request("/status.json")).json
		XCTAssertEqual(status["name"] as? String, "Test <Show>")
		XCTAssertEqual(status["live"] as? Bool, true)
		XCTAssertEqual(status["bitrates"] as? [Int], [128])
		XCTAssertEqual(status["hls"] as? Bool, true)
		XCTAssertEqual(status["aac"] as? Bool, true)
		XCTAssertEqual(status["mp3"] as? Bool, false)
		XCTAssertEqual(status["flac"] as? Bool, true)
		XCTAssertEqual(status["pcm"] as? Bool, true)
		XCTAssertEqual(status["publicURL"] as? String, "https://cast.example.com/")
		XCTAssertEqual(status["listeners"] as? Int, 0)
		XCTAssertNil(status["nowPlaying"])
		let manifest = await router.handle(TestRouter.request("/manifest.webmanifest"))
		XCTAssertEqual(manifest.contentType, "application/manifest+json")
		XCTAssertEqual(manifest.json["name"] as? String, "Test <Show>")
		XCTAssertEqual(manifest.json["display"] as? String, "standalone")
	}

	func testHLSPlaylistsAndSegments() async throws {
		let (router, _, _, _, _) = try liveRouter()
		let master = await router.handle(TestRouter.request("/hls/master.m3u8"))
		XCTAssertEqual(master.status, 200)
		XCTAssertTrue(master.bodyText.contains("#EXT-X-STREAM-INF:BANDWIDTH=152000,AVERAGE-BANDWIDTH=136000,CODECS=\"mp4a.40.2\"\n128/stream.m3u8"))
		XCTAssertTrue(master.bodyText.contains("#EXT-X-SESSION-DATA:DATA-ID=\"com.microcast.title\",VALUE=\"Test <Show>\""))
		let media = await router.handle(TestRouter.request("/hls/128/stream.m3u8", from: "10.0.0.7"))
		XCTAssertEqual(media.status, 200)
		XCTAssertEqual(media.contentType, "application/vnd.apple.mpegurl")
		XCTAssertTrue(media.bodyText.contains("#EXT-X-PRELOAD-HINT:TYPE=PART,URI=\"seg1.1.m4s\""))
		XCTAssertEqual(router.listenerCount, 1, "a playlist poll counts as a listener")
		let blocking = await router.handle(TestRouter.request("/hls/128/stream.m3u8", query: ["_HLS_msn": "0", "_HLS_part": "2"]))
		XCTAssertEqual(blocking.status, 200, "already available: answered at once")
		let r1 = await router.handle(TestRouter.request("/hls/128/init.mp4"))
		XCTAssertEqual(r1.bodyData, Data([0, 0, 0, 8] + Array("ftyp".utf8)))
		let r2 = await router.handle(TestRouter.request("/hls/128/seg0.m4s"))
		XCTAssertEqual(r2.bodyData?.count, 6)
		let r3 = await router.handle(TestRouter.request("/hls/128/seg1.0.m4s"))
		XCTAssertEqual(r3.bodyData, Data([6]))
		let r4 = await router.handle(TestRouter.request("/hls/128/seg1.9.m4s"))
		XCTAssertEqual(r4.status, 404, "a part past the end answers without waiting")
		let r5 = await router.handle(TestRouter.request("/hls/999/stream.m3u8"))
		XCTAssertEqual(r5.status, 404)
		let r6 = await router.handle(TestRouter.request("/hls/128/other.txt"))
		XCTAssertEqual(r6.status, 404)
	}

	func testDirectStreamsCarryHeadersAndData() async throws {
		let (router, _, aac, flac, pcm) = try liveRouter()
		let response = await router.handle(TestRouter.request("/stream-128.aac"))
		XCTAssertEqual(response.contentType, "audio/aac")
		XCTAssertEqual(response.headers["icy-name"], "Test <Show>")
		XCTAssertEqual(response.headers["icy-br"], "128")
		XCTAssertEqual(response.headers["Cache-Control"], "no-store")
		let stream = try XCTUnwrap(response.bodyStream)
		aac.broadcaster.publish(Data([0xFF, 0xF1]))
		var first: Data?
		for await chunk in stream { first = chunk; break }
		XCTAssertEqual(first, Data([0xFF, 0xF1]))
		XCTAssertEqual(router.listenerCount, 1)

		let flacResponse = await router.handle(TestRouter.request("/stream.flac"))
		XCTAssertEqual(flacResponse.contentType, "audio/flac")
		var header: Data?
		for await chunk in try XCTUnwrap(flacResponse.bodyStream) { header = chunk; break }
		XCTAssertEqual(String(decoding: header?.prefix(4) ?? Data(), as: UTF8.self), "fLaC", "new listeners get the stream header first")
		_ = flac

		let pcmResponse = await router.handle(TestRouter.request("/stream.pcm"))
		XCTAssertEqual(pcmResponse.headers["X-Sample-Rate"], "48000")
		XCTAssertEqual(pcmResponse.headers["X-Channels"], "2")
		_ = pcm
		let r7 = await router.handle(TestRouter.request("/stream-64.aac"))
		XCTAssertEqual(r7.status, 404, "unconfigured bitrate")
		let r8 = await router.handle(TestRouter.request("/stream-128.mp3"))
		XCTAssertEqual(r8.status, 404, "format off")
		let r9 = await router.handle(TestRouter.request("/nothing"))
		XCTAssertEqual(r9.status, 404)
		let r10 = await router.handle(TestRouter.request("/", method: "POST"))
		XCTAssertEqual(r10.status, 405)
	}

	func testPasswordGuardsEverythingExceptChallenges() async throws {
		let challenges = ACMEChallengeStore()
		challenges.publish(token: "tok", keyAuthorization: "tok.thumb")
		let router = TestRouter.make(password: "secret", challenges: challenges)
		let denied = await router.handle(TestRouter.request("/status.json"))
		XCTAssertEqual(denied.status, 401)
		XCTAssertEqual(denied.headers["WWW-Authenticate"], "Basic realm=\"HLSCast\", charset=\"UTF-8\"".replacingOccurrences(of: "HLSCast", with: "MicroCast"))
		let credentials = Data("anyone:secret".utf8).base64EncodedString()
		let r11 = await router.handle(TestRouter.request("/status.json", headers: ["authorization": "Basic \(credentials)"]))
		XCTAssertEqual(r11.status, 200)
		let challenge = await router.handle(TestRouter.request("/.well-known/acme-challenge/tok"))
		XCTAssertEqual(challenge.status, 200)
		XCTAssertEqual(challenge.bodyText, "tok.thumb")
		let r12 = await router.handle(TestRouter.request("/.well-known/acme-challenge/other"))
		XCTAssertEqual(r12.status, 404)
	}

	func testOffAirRouterKeepsPageAndStatusButNotStreams() async throws {
		let lastLive = Date(timeIntervalSince1970: 1_700_000_000)
		let router = Router.offAir(name: "Idle", password: "", publicURL: OSAllocatedUnfairLock(initialState: nil), challenges: ACMEChallengeStore(), lastLive: lastLive)
		let status = await router.handle(TestRouter.request("/status.json")).json
		XCTAssertEqual(status["live"] as? Bool, false)
		XCTAssertEqual(status["lastLive"] as? Double, 1_700_000_000)
		XCTAssertEqual(status["hls"] as? Bool, false)
		let r13 = await router.handle(TestRouter.request("/"))
		XCTAssertEqual(r13.status, 200)
		for path in ["/hls/master.m3u8", "/hls/128/stream.m3u8", "/stream-128.aac", "/stream.flac", "/stream.pcm"] {
			let response = await router.handle(TestRouter.request(path))
			XCTAssertEqual(response.status, 503, path)
			XCTAssertEqual(response.headers["Retry-After"], "30", path)
		}
		XCTAssertEqual(router.listenerCount, 0)
	}

	func testListenerTrackerCountsRecentAddresses() {
		let tracker = ListenerTracker()
		tracker.touch("a"); tracker.touch("b"); tracker.touch("a")
		XCTAssertEqual(tracker.activeCount, 2)
	}
}
