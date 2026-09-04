import XCTest
@testable import MicroCast

final class MiscTests: XCTestCase {
	override func tearDown() {
		for key in ["enableTestFlag", "streamName", "jingleDuckDecibels"] { UserDefaults.standard.removeObject(forKey: key) }
	}

	func testResponseHelpers() {
		XCTAssertEqual(HTTPResponse.text(404, "x").status, 404)
		XCTAssertEqual(HTTPResponse.data(Data(), type: "audio/mp4").headers["Cache-Control"], "no-cache")
		XCTAssertEqual(HTTPResponse.data(Data(), type: "audio/mp4", cache: "max-age=60").headers["Cache-Control"], "max-age=60")
		let (stream, _) = AsyncStream<Data>.makeStream()
		let response = HTTPResponse.stream(stream, type: "audio/aac", headers: ["icy-name": "n"])
		XCTAssertEqual(response.headers["Cache-Control"], "no-store")
		XCTAssertEqual(response.headers["icy-name"], "n")
	}

	func testRequestParsingDecodesPercentEscapes() throws {
		let request = try XCTUnwrap(HTTPServer.parse(Data("GET /a%20b?x=1 HTTP/1.1\r\n".utf8)))
		XCTAssertEqual(request.path, "/a b")
		XCTAssertEqual(request.query["x"], "1")
	}

	func testTunnelBinaryLookup() throws {
		XCTAssertEqual(try Tunnel.locate("ls", hint: "").path, "/bin/ls")
		XCTAssertThrowsError(try Tunnel.locate("definitely-not-installed-\(UUID().uuidString)", hint: "install it")) { error in
			XCTAssertTrue(error.localizedDescription.contains("install it"))
		}
	}

	func testPageURLsStartWithLocalhost() {
		let urls = Streamer.pageURLs(port: 8123)
		XCTAssertEqual(urls.first?.absoluteString, "http://localhost:8123/")
		XCTAssertTrue(urls.allSatisfy { $0.port == 8123 })
	}

	func testSettingsDefaultsAndSnapshot() {
		XCTAssertTrue(Settings.isEnabled("enableTestFlag"), "unset means enabled")
		UserDefaults.standard.set(false, forKey: "enableTestFlag")
		XCTAssertFalse(Settings.isEnabled("enableTestFlag"))
		XCTAssertEqual(Settings.jingleDuckDecibels, -12)
		UserDefaults.standard.set(0.0, forKey: "jingleDuckDecibels")
		XCTAssertEqual(Settings.jingleDuckDecibels, 0, "0 dB is a real value, not 'unset'")
		UserDefaults.standard.set(-99.0, forKey: "jingleDuckDecibels")
		XCTAssertEqual(Settings.jingleDuckDecibels, -30, "clamped")
		let before = Settings.snapshot
		UserDefaults.standard.set("Other name", forKey: "streamName")
		XCTAssertNotEqual(before, Settings.snapshot, "a changed setting shows up as a restart-worthy difference")
		XCTAssertEqual(Settings.streamName, "Other name")
	}

	func testOpenSSLErrorsSurface() {
		XCTAssertThrowsError(try OpenSSL.run(["x509", "-in", "/nonexistent.pem"]))
	}

	func testJingleBankAvoidsImmediateRepeats() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bank-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let a = directory.appendingPathComponent("a.mp3"), b = directory.appendingPathComponent("b.wav"), ignored = directory.appendingPathComponent("notes.txt")
		for url in [a, b, ignored] { try Data().write(to: url) }
		let bank = JingleBank(folder: directory)
		XCTAssertEqual(bank.files.map(\.lastPathComponent), ["a.mp3", "b.wav"])
		for _ in 0..<30 { XCTAssertEqual(bank.pick(avoiding: a)?.lastPathComponent, "b.wav") }
		XCTAssertNil(JingleBank(folder: directory.appendingPathComponent("missing")).pick(avoiding: nil))
	}

	func testDiscoveryDoesNotCrashWithoutHardware() {
		_ = AudioDevices.inputs()
		_ = AudioApp.running()
		XCTAssertNotNil(NowPlayingMonitor.players.first { $0.bundleID == "com.apple.Music" })
		XCTAssertTrue(NowPlayingMonitor.trackScript(for: "Spotify").contains("tell application \"Spotify\""))
	}
}
