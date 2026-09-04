import XCTest
@testable import MicroCast

final class SettingsTests: XCTestCase {
	func testBitrateParsing() {
		XCTAssertEqual(Settings.parseBitrates("64, 128, 256, 320"), [64, 128, 256, 320])
		XCTAssertEqual(Settings.parseBitrates(""), Settings.defaultBitrates)
		XCTAssertEqual(Settings.parseBitrates("abc"), Settings.defaultBitrates)
		XCTAssertEqual(Settings.parseBitrates("32 100 400 100"), [64, 100, 320], "clamped to the encoder range, deduplicated, sorted")
		XCTAssertEqual(Settings.parseBitrates("96;192\n256").count, 3, "any separator")
		XCTAssertEqual(Settings.parseBitrates((64...80).map(String.init).joined(separator: ",")).count, 8, "at most eight renditions")
	}
}
