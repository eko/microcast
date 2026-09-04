import CoreMedia
import XCTest
@testable import MicroCast

final class StreamsTests: XCTestCase {
	func testMixerBuildsSampleBuffersWithRunningTimestamps() {
		let buffers = TestAudio.sampleBuffers(seconds: 0.1)
		XCTAssertEqual(buffers.count, 5)
		XCTAssertEqual(CMSampleBufferGetNumSamples(buffers[0].0), 960)
		XCTAssertEqual(buffers[0].0.presentationTimeStamp.value, 0)
		XCTAssertEqual(buffers[3].0.presentationTimeStamp.value, 3 * 960)
		XCTAssertEqual(buffers[3].0.presentationTimeStamp.timescale, 48_000)
		let description = CMSampleBufferGetFormatDescription(buffers[0].0)!
		let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)!.pointee
		XCTAssertEqual(asbd.mSampleRate, 48_000)
		XCTAssertEqual(asbd.mChannelsPerFrame, 2)
		XCTAssertEqual(asbd.mBitsPerChannel, 16)
		XCTAssertEqual(buffers[0].1.count, 960 * 4)
	}

	func testMixerAppliesAQueuedJingle() {
		let mixer = AudioMixer()
		mixer.configure(duckDecibels: -12, jingleVolume: 1)
		var outputs: [Data] = []
		mixer.output = { outputs.append($1) }
		XCTAssertTrue(mixer.play([Float](repeating: 0.9, count: 48_000 * 2))) // a one-second jingle
		XCTAssertFalse(mixer.play([0.1, 0.1]), "one at a time")
		let silence = Data(count: 960 * 4)
		for _ in 0..<30 { mixer.append(silence) } // 0.6 s: past the half-second fade-down
		XCTAssertTrue(mixer.isPlayingJingle)
		let early = outputs[1].withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
		XCTAssertEqual(early.max() ?? 0, 0, "still fading the programme down, no jingle yet")
		let later = outputs[27].withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
		XCTAssertGreaterThan(later.max() ?? 0, 20_000, "the jingle is audible in the output")
	}

	func testPCMStreamCoalescesIntoTwentyMillisecondChunks() async throws {
		let pcm = PCMStream()
		let stream = pcm.broadcaster.subscribe()
		for _ in 0..<3 { pcm.append(TestAudio.sine(frames: 1000)) }
		try await Task.sleep(for: .milliseconds(100))
		pcm.broadcaster.closeAll()
		var sizes: [Int] = []
		for await chunk in stream { sizes.append(chunk.count) }
		XCTAssertEqual(sizes, [3840, 3840, 3840], "3000 frames → three 960-frame chunks, 120 frames pending")
	}

	func testAACStreamProducesValidADTSFrames() async throws {
		let aac = try AACStream(bitrate: 128)
		let stream = aac.broadcaster.subscribe()
		for _ in 0..<50 { aac.append(TestAudio.sine(frames: 960)) } // one second
		try await Task.sleep(for: .milliseconds(300))
		aac.broadcaster.closeAll()
		var bytes = Data()
		for await chunk in stream { bytes.append(chunk) }
		var offset = 0, frames = 0
		while offset + 7 <= bytes.count {
			XCTAssertEqual(bytes[offset], 0xFF); XCTAssertEqual(bytes[offset + 1], 0xF1, "ADTS sync, MPEG-4, no CRC")
			let length = Int(bytes[offset + 3] & 0x03) << 11 | Int(bytes[offset + 4]) << 3 | Int(bytes[offset + 5]) >> 5
			XCTAssertGreaterThan(length, 7)
			offset += length
			frames += 1
		}
		XCTAssertEqual(offset, bytes.count, "frames tile the stream exactly")
		XCTAssertEqual(frames, 46, accuracy: 2, "48000 / 1024 packets per second")
	}

	func testFLACStreamStartsWithHeaderThenFrames() async throws {
		let flac = try FLACStream(title: "Show")
		let stream = flac.broadcaster.subscribe()
		for _ in 0..<50 { flac.append(TestAudio.sine(frames: 960)) }
		try await Task.sleep(for: .milliseconds(300))
		flac.broadcaster.closeAll()
		var chunks: [Data] = []
		for await chunk in stream { chunks.append(chunk) }
		XCTAssertEqual(String(decoding: chunks[0].prefix(4), as: UTF8.self), "fLaC")
		XCTAssertTrue(String(decoding: chunks[0], as: UTF8.self).contains("TITLE=Show"))
		XCTAssertEqual(chunks[1][0], 0xFF); XCTAssertEqual(chunks[1][1] & 0xFC, 0xF8, "FLAC frame sync")
		let frames = chunks.dropFirst().reduce(0) { $0 + $1.count }
		XCTAssertGreaterThan(frames, 1000)
	}

	func testMP3StreamThroughLame() async throws {
		guard let lame = MP3Stream.findLame() else { throw XCTSkip("lame is not installed") }
		let mp3 = try MP3Stream(lame: lame, bitrate: 128, title: "Show")
		let stream = mp3.broadcaster.subscribe()
		for _ in 0..<50 { mp3.append(TestAudio.sine(frames: 960)) }
		try await Task.sleep(for: .milliseconds(800))
		mp3.stop()
		var bytes = Data()
		for await chunk in stream { bytes.append(chunk) }
		XCTAssertEqual(String(decoding: bytes.prefix(3), as: UTF8.self), "ID3")
		let audio = bytes.dropFirst(10 + 10 + 1 + 4) // past the ID3 tag with its TIT2 "Show"
		XCTAssertNotNil(audio.firstIndex(of: 0xFF), "MP3 frame sync present")
		XCTAssertGreaterThan(audio.count, 8000, "about 16 kB for a second at 128 kbps")
	}

	func testRecorderWritesEveryChunk() async throws {
		let broadcaster = Broadcaster()
		broadcaster.preamble = Data("HDR".utf8)
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString).bin")
		defer { try? FileManager.default.removeItem(at: url) }
		let recorder = try Recorder(stream: broadcaster.subscribe(), url: url)
		broadcaster.publish(Data("abc".utf8))
		broadcaster.publish(Data("def".utf8))
		try await Task.sleep(for: .milliseconds(200))
		XCTAssertEqual(recorder.bytesWritten, 9)
		recorder.stop()
		try await Task.sleep(for: .milliseconds(100))
		XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), "HDRabcdef")
	}
}
