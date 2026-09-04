import XCTest
@testable import MicroCast

final class EncodingTests: XCTestCase {
	func testADTSHeader() {
		XCTAssertEqual([UInt8](ADTS.header(payloadLength: 100)), [0xFF, 0xF1, 0x4C, 0x80, 0x0D, 0x7F, 0xFC])
	}

	func testID3TagCarriesTheTitle() {
		let tag = MP3Stream.id3Tag(title: "My Show")
		let bytes = [UInt8](tag)
		XCTAssertEqual(Array(bytes[0..<5]), [0x49, 0x44, 0x33, 0x04, 0x00])
		let frameSize = 10 + 1 + 7
		XCTAssertEqual(tag.count, 10 + frameSize)
		XCTAssertEqual(Array(bytes[6..<10]), [0, 0, 0, UInt8(frameSize)], "syncsafe tag size")
		XCTAssertEqual(String(decoding: bytes[10..<14], as: UTF8.self), "TIT2")
		XCTAssertEqual(bytes[20], 0x03, "UTF-8 encoding marker")
		XCTAssertEqual(String(decoding: bytes[21...], as: UTF8.self), "My Show")
	}

	func testFLACHeaderHasStreamInfoThenVorbisComment() {
		let streamInfo = Data(repeating: 0xAB, count: 34)
		let header = FLACStream.streamHeader(cookie: Data([1, 2, 3]) + streamInfo, title: "Show")
		let bytes = [UInt8](header)
		XCTAssertEqual(String(decoding: bytes[0..<4], as: UTF8.self), "fLaC")
		XCTAssertEqual(Array(bytes[4..<8]), [0x00, 0x00, 0x00, 0x22], "STREAMINFO, not the last block")
		XCTAssertEqual(Data(bytes[8..<42]), streamInfo)
		XCTAssertEqual(bytes[42], 0x84, "last block, type VORBIS_COMMENT")
		let blockLength = Int(bytes[43]) << 16 | Int(bytes[44]) << 8 | Int(bytes[45])
		XCTAssertEqual(46 + blockLength, bytes.count)
		XCTAssertTrue(String(decoding: bytes[46...], as: UTF8.self).contains("TITLE=Show"))
	}

	func testTitleIsAppendedToTheInitSegmentMoov() {
		func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
			let size = 8 + payload.count
			return [UInt8(size >> 24), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)] + Array(type.utf8) + payload
		}
		let ftyp = box("ftyp", Array("iso5".utf8))
		let moov = box("moov", box("mvhd", [UInt8](repeating: 0, count: 4)))
		let result = [UInt8](HLSVariant.addingTitle("Show", to: Data(ftyp + moov)))
		XCTAssertEqual(Array(result[0..<ftyp.count]), ftyp, "ftyp untouched")
		let nam: [UInt8] = [0, 0, 0, 16, 0xA9] + Array("nam".utf8) + [0, 4, 0, 0] + Array("Show".utf8) // ©nam, MacRoman ©
		let udta = box("udta", nam)
		XCTAssertEqual(result.count, ftyp.count + moov.count + udta.count)
		let moovSize = Int(result[ftyp.count]) << 24 | Int(result[ftyp.count + 1]) << 16 | Int(result[ftyp.count + 2]) << 8 | Int(result[ftyp.count + 3])
		XCTAssertEqual(moovSize, moov.count + udta.count)
		XCTAssertEqual(Array(result.suffix(udta.count)), udta)
	}
}
