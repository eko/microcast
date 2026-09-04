import XCTest
@testable import MicroCast

final class HLSVariantTests: XCTestCase {
	func testAVAssetWriterProducesInitAndPartsWithTheTitle() async throws {
		let variant = HLSVariant(bitrate: 128, partDuration: 0.334, segmentDuration: 2, title: "My Show")
		for (sampleBuffer, _) in TestAudio.sampleBuffers(seconds: 3) { variant.append(sampleBuffer) }
		let deadline = Date().addingTimeInterval(15)
		while Date() < deadline, variant.playlist.render().components(separatedBy: "#EXT-X-PART:").count < 7 {
			try await Task.sleep(for: .milliseconds(200))
		}
		variant.stop()
		let playlist = variant.playlist.render()
		XCTAssertTrue(variant.playlist.hasContent)
		XCTAssertTrue(playlist.contains("#EXT-X-PART-INF:PART-TARGET=0.356"))
		XCTAssertTrue(playlist.contains("#EXTINF:"), "at least one complete 2 s segment out of 3 s of audio")
		XCTAssertTrue(playlist.contains(",My Show\n"), "the title rides on EXTINF")
		let durations = playlist.components(separatedBy: "\n").compactMap { line -> Double? in
			guard line.hasPrefix("#EXT-X-PART:DURATION=") else { return nil }
			return Double(line.dropFirst("#EXT-X-PART:DURATION=".count).prefix(5))
		}
		XCTAssertGreaterThanOrEqual(durations.count, 6)
		for duration in durations.dropLast() { XCTAssertEqual(duration, 0.334, accuracy: 0.03, "parts are cut on AAC frames") }
		let initSegment = try XCTUnwrap(variant.playlist.initialization)
		XCTAssertEqual(String(decoding: initSegment.prefix(8).suffix(4), as: UTF8.self), "ftyp")
		XCTAssertNotNil(initSegment.range(of: Data([0xA9]) + Data("nam".utf8)), "moov/udta/©nam injected")
		XCTAssertNotNil(initSegment.range(of: Data("My Show".utf8)))
		XCTAssertNotNil(variant.playlist.part(sequence: 0, index: 0))
		XCTAssertNotNil(variant.playlist.segment(sequence: 0))
	}
}
