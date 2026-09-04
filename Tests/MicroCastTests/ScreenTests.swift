import XCTest
@testable import MicroCast

final class ScreenTests: XCTestCase {
	func testRegionClampsInsideTheDisplay() {
		let display = CGSize(width: 1920, height: 1080)
		XCTAssertEqual(ScreenRegion(x: 100, y: 100, width: 800, height: 600).clamped(to: display), ScreenRegion(x: 100, y: 100, width: 800, height: 600))
		XCTAssertEqual(ScreenRegion(x: 1800, y: 1000, width: 800, height: 600).clamped(to: display), ScreenRegion(x: 1120, y: 480, width: 800, height: 600), "pushed back inside")
		XCTAssertEqual(ScreenRegion(x: 0, y: 0, width: 5000, height: 5000).clamped(to: display), ScreenRegion(x: 0, y: 0, width: 1920, height: 1080), "capped to the display")
		XCTAssertEqual(ScreenRegion(x: -50, y: -50, width: 100, height: 100).clamped(to: display), ScreenRegion(x: 0, y: 0, width: 100, height: 100))
	}

	func testOutputSizeCapsTheLongEdgeAndStaysEven() {
		let region = ScreenRegion(x: 0, y: 0, width: 800, height: 600)
		XCTAssertEqual(region.outputSize(scale: 2, maxWidth: 1280).width, 1280, "1600 px capped to 1280")
		XCTAssertEqual(region.outputSize(scale: 2, maxWidth: 1280).height, 960)
		let small = region.outputSize(scale: 1, maxWidth: 1280)
		XCTAssertEqual(small.width, 800, "already under the cap, left as is")
		XCTAssertEqual(small.height, 600)
		XCTAssertEqual(region.outputSize(scale: 2, maxWidth: 1000).width % 2, 0, "even width")
	}

	func testMJPEGPartFraming() {
		let part = MJPEG.part(Data([0xFF, 0xD8, 0xFF, 0xD9]))
		let text = String(decoding: part, as: UTF8.self)
		XCTAssertTrue(text.hasPrefix("--microcastframe\r\nContent-Type: image/jpeg\r\nContent-Length: 4\r\n\r\n"))
		XCTAssertTrue(text.hasSuffix("\r\n"))
		XCTAssertTrue(MJPEG.contentType.contains("boundary=microcastframe"))
		XCTAssertEqual(part.suffix(6).prefix(4), Data([0xFF, 0xD8, 0xFF, 0xD9]))
	}
}
