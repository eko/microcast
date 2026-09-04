import CoreMedia
import Foundation
@testable import MicroCast

enum TestAudio {
	/// Interleaved 48 kHz stereo 16-bit sine, `frames` long.
	static func sine(frames: Int, frequency: Double = 440, amplitude: Double = 0.5) -> Data {
		var data = Data(capacity: frames * 4)
		for frame in 0..<frames {
			let value = Int16(amplitude * 32767 * sin(2 * .pi * frequency * Double(frame) / 48_000))
			withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
			withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
		}
		return data
	}

	/// Sample buffers for `seconds` of sine, in 20 ms pieces, through the real mixer.
	static func sampleBuffers(seconds: Double) -> [(CMSampleBuffer, Data)] {
		let mixer = AudioMixer()
		var buffers: [(CMSampleBuffer, Data)] = []
		mixer.output = { buffers.append(($0, $1)) }
		let pieces = Int(seconds * 50)
		for _ in 0..<pieces { mixer.append(sine(frames: 960)) }
		return buffers
	}
}

enum TestRouter {
	static func make(
		hls: [Int: HLSVariant] = [:], aac: [Int: AACStream] = [:], mp3: [Int: MP3Stream] = [:], flac: FLACStream? = nil, pcm: PCMStream? = nil,
		bitrates: [Int] = [64, 128], live: Bool = true, lastLive: Date? = nil, name: String = "Test <Show>", password: String = "",
		publicURL: URL? = nil, challenges: ACMEChallengeStore = ACMEChallengeStore(), history: ListenerHistory = ListenerHistory(), nowPlaying: NowPlayingMonitor? = nil
	) -> Router {
		Router(
			hls: hls, aac: aac, mp3: mp3, flac: flac, pcm: pcm, bitrates: bitrates, history: history, challenges: challenges,
			nowPlaying: nowPlaying, live: live, lastLive: lastLive, name: name, partDuration: 0.334, password: password,
			publicURL: OSAllocatedUnfairLock(initialState: publicURL)
		)
	}

	static func request(_ path: String, method: String = "GET", query: [String: String] = [:], headers: [String: String] = [:], from address: String = "10.0.0.1") -> HTTPRequest {
		HTTPRequest(method: method, path: path, query: query, headers: headers, remoteAddress: address)
	}
}

extension HTTPResponse {
	var bodyData: Data? {
		if case .data(let data) = body { return data }
		return nil
	}

	var bodyText: String { bodyData.map { String(decoding: $0, as: UTF8.self) } ?? "" }

	var bodyStream: AsyncStream<Data>? {
		if case .stream(let stream) = body { return stream }
		return nil
	}

	var json: [String: Any] {
		(bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
	}
}

import os
