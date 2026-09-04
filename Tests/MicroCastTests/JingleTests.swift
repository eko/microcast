import AVFoundation
import XCTest
@testable import MicroCast

final class JingleTests: XCTestCase {
	func testDuckingEnvelopeAndOverlay() {
		var mixer = DuckingMixer(duckGain: 0.25, jingleGain: 1, fadeDownFrames: 100, fadeUpFrames: 200)
		let jingleFrames = 300
		mixer.start([Float](repeating: 0.5, count: jingleFrames * 2))
		var samples = [Int16](repeating: 16000, count: 1000 * 2) // a steady programme
		samples.withUnsafeMutableBufferPointer { mixer.process($0) }
		let frame = { (index: Int) in Int(samples[index * 2]) }
		XCTAssertLessThan(frame(50), 16000, "fading down")
		XCTAssertEqual(frame(250), Int(16000 * 0.25 + 0.5 * 32767), accuracy: 40, "ducked programme plus jingle")
		XCTAssertEqual(frame(403), Int(16000 * 0.25), accuracy: 200, "just after the jingle, still ducked")
		XCTAssertEqual(frame(450), Int(16000 * (0.25 + 0.75 * 49 / 200)), accuracy: 200, "a quarter of the way back up")
		XCTAssertEqual(frame(900), 16000, accuracy: 2, "programme restored")
		XCTAssertFalse(mixer.isActive)
	}

	func testSchedulerFiresOnlyWithinOnePoll() {
		XCTAssertNil(JingleScheduler.delay(remaining: 30, lead: 2, interval: 1))
		XCTAssertEqual(JingleScheduler.delay(remaining: 3.2, lead: 2, interval: 1)!, 1.2, accuracy: 0.001)
		XCTAssertEqual(JingleScheduler.delay(remaining: 1.5, lead: 2, interval: 1), 0, "already past the point: now")
	}

	func testProgressParsingHandlesSpotifyMilliseconds() {
		let music = NowPlayingMonitor.parseProgress("T\nA\nAl\nid\n12.5\n200.25\n", source: "Music")
		XCTAssertEqual(music?.position, 12.5)
		XCTAssertEqual(music?.duration, 200.25)
		let spotify = NowPlayingMonitor.parseProgress("T\nA\nAl\nid\n12,5\n200250\n", source: "Spotify")
		XCTAssertEqual(spotify?.duration ?? 0, 200.25, accuracy: 0.001, "milliseconds and a French decimal comma")
		XCTAssertNil(NowPlayingMonitor.parseProgress("T\nA\nAl\nid\n\n\n", source: "Music"), "radio streams have no position")
	}

	func testNoDuckKeepsTheProgrammeAtFullLevel() {
		var mixer = DuckingMixer(duckGain: 1, jingleGain: 1, fadeDownFrames: 100, fadeUpFrames: 100)
		mixer.start([Float](repeating: 0.1, count: 200))
		var samples = [Int16](repeating: 10000, count: 400)
		samples.withUnsafeMutableBufferPointer { mixer.process($0) }
		XCTAssertEqual(Int(samples[2]), 10000 + Int(0.1 * 32767), accuracy: 2, "jingle added, programme untouched")
		XCTAssertEqual(samples[300], 10000)
		XCTAssertFalse(mixer.isActive)
	}

	func testMixerIsInertWhenIdle() {
		var mixer = DuckingMixer()
		var samples = [Int16](repeating: 1234, count: 200)
		samples.withUnsafeMutableBufferPointer { mixer.process($0) }
		XCTAssertEqual(samples[100], 1234)
	}

	/// A minimal RIFF/WAVE file: 16-bit mono PCM.
	private static func wav(mono16 samples: [Int16], sampleRate: UInt32) -> Data {
		var data = Data()
		func u32(_ value: UInt32) { data.append(contentsOf: withUnsafeBytes(of: value.littleEndian, Array.init)) }
		func u16(_ value: UInt16) { data.append(contentsOf: withUnsafeBytes(of: value.littleEndian, Array.init)) }
		let payload = UInt32(samples.count * 2)
		data.append(contentsOf: Array("RIFF".utf8)); u32(36 + payload); data.append(contentsOf: Array("WAVE".utf8))
		data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
		data.append(contentsOf: Array("data".utf8)); u32(payload)
		for sample in samples { u16(UInt16(bitPattern: sample)) }
		return data
	}

	func testDecodesAndResamplesAWavFile() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jingles-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = directory.appendingPathComponent("beep.wav")
		try Self.wav(mono16: [Int16](repeating: 16_383, count: 44_100), sampleRate: 44_100).write(to: url)
		let samples = try JingleBank.decode(url)
		XCTAssertEqual(samples.count / 2, 48_000, accuracy: 100, "one second at 48 kHz")
		XCTAssertEqual(samples[samples.count / 2], 0.5, accuracy: 0.05, "mono duplicated to both channels")
		XCTAssertEqual(samples[samples.count / 2 + 1], 0.5, accuracy: 0.05)
		let bank = JingleBank(folder: directory)
		XCTAssertEqual(bank.files.map(\.lastPathComponent), ["beep.wav"])
		XCTAssertEqual(bank.pick(avoiding: url)?.resolvingSymlinksInPath(), url.resolvingSymlinksInPath(), "a single file may repeat")
	}
}
