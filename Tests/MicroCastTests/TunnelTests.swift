import XCTest
@testable import MicroCast

final class TunnelTests: XCTestCase {
	func testCloudflareURLIsAnnouncedOnlyOnceRegisteredEvenAfterTranscriptTrim() {
		var parser = TunnelOutputParser(urlPattern: #"https://[a-z0-9-]+\.trycloudflare\.com"#, readyPattern: "Registered tunnel connection")
		XCTAssertNil(parser.feed("INF |  https://quiet-river-1234.trycloudflare.com  |\n"))
		XCTAssertNil(parser.feed(String(repeating: "INF connectivity precheck line\n", count: 200)), "6 KB of banner must not lose the URL")
		XCTAssertEqual(parser.feed("INF Registered tunnel connection connIndex=0\n"), URL(string: "https://quiet-river-1234.trycloudflare.com"))
		XCTAssertNil(parser.feed("INF Registered tunnel connection connIndex=1\n"), "announced once")
	}

	func testNgrokURLIsAnnouncedImmediately() {
		var parser = TunnelOutputParser(urlPattern: #"https://[a-z0-9.-]+\.ngrok[a-z0-9.-]*\.(?:app|dev|io)"#, readyPattern: nil)
		XCTAssertEqual(parser.feed("t=1 lvl=info msg=\"started tunnel\" url=https://0f9f-1-2-3-4.ngrok-free.app\n"), URL(string: "https://0f9f-1-2-3-4.ngrok-free.app"))
	}

	func testRecentOutputKeepsTheTail() {
		var parser = TunnelOutputParser(urlPattern: nil, readyPattern: nil)
		_ = parser.feed("first line\n")
		_ = parser.feed("error: something broke\n")
		XCTAssertTrue(parser.recentOutput.hasSuffix("error: something broke"))
	}
}
