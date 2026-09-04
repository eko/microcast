import XCTest
@testable import MicroCast

final class NowPlayingTests: XCTestCase {
	func testParsesTrackLines() throws {
		let track = try XCTUnwrap(NowPlayingMonitor.parseTrack("Blue in Green\nMiles Davis\nKind of Blue\nABC123\n", source: "Music"))
		XCTAssertEqual(track.title, "Blue in Green")
		XCTAssertEqual(track.artist, "Miles Davis")
		XCTAssertEqual(track.album, "Kind of Blue")
		XCTAssertEqual(track.trackID, "ABC123")
		XCTAssertNil(NowPlayingMonitor.parseTrack("", source: "Music"), "empty output means nothing is playing")
		XCTAssertEqual(NowPlayingMonitor.parseTrack("T\nA\nAl\n\n", source: "Spotify")?.trackID, "T|A", "falls back to title and artist")
	}

	func testParsesAppleScriptBinary() {
		let (data, type) = NowPlayingMonitor.parseAppleScriptData("«data JPEGFFD8FFE0»\n")
		XCTAssertEqual([UInt8](data ?? Data()), [0xFF, 0xD8, 0xFF, 0xE0])
		XCTAssertEqual(type, "image/jpeg")
		XCTAssertEqual(NowPlayingMonitor.parseAppleScriptData("«data PNGf89504E47»").1, "image/png")
		XCTAssertNil(NowPlayingMonitor.parseAppleScriptData("missing").0)
	}

	func testJSONCarriesArtworkPath() {
		var track = NowPlaying(source: "Spotify", title: "T", artist: "A", album: "B", trackID: "1")
		XCTAssertNil(track.json["artwork"])
		track.artworkID = "abcd"
		XCTAssertEqual(track.json["artwork"] as? String, "/artwork?id=abcd")
	}
}
