import Foundation

/// MP3 through an external `lame` process, since macOS ships no MP3 encoder: PCM in on stdin, MP3 out on stdout.
final class MP3Stream {
	static func findLame() -> URL? {
		let fromPath = ProcessInfo.processInfo.environment["PATH"]?
			.split(separator: ":")
			.map { "\($0)/lame" } ?? []
		let candidates = ["/opt/homebrew/bin/lame", "/usr/local/bin/lame"] + fromPath
		return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
	}

	let bitrate: Int
	let broadcaster = Broadcaster()
	private let process = Process()
	private let input = Pipe()
	private let output = Pipe()
	private let queue: DispatchQueue

	init(lame: URL, bitrate: Int, title: String) throws {
		self.bitrate = bitrate
		queue = DispatchQueue(label: "local.microcast.mp3.\(bitrate)")
		broadcaster.preamble = Self.id3Tag(title: title)
		process.executableURL = lame
		process.arguments = [
			"-r", "-s", "48", "--bitwidth", "16", "--signed", "--little-endian",
			"-m", "j", "-b", "\(bitrate)", "-q", "2", "-t", "--flush", "--quiet", "-", "-",
		]
		process.standardInput = input
		process.standardOutput = output
		process.standardError = FileHandle.nullDevice
		let broadcaster = broadcaster
		output.fileHandleForReading.readabilityHandler = { handle in
			let data = handle.availableData
			if data.isEmpty {
				handle.readabilityHandler = nil
			} else {
				broadcaster.publish(data)
			}
		}
		try process.run()
	}

	/// A minimal ID3v2.4 tag carrying TIT2, sent to every new listener before the audio.
	static func id3Tag(title: String) -> Data {
		let text = Data(title.utf8)
		var frame = Data("TIT2".utf8)
		frame.append(syncsafe(UInt32(text.count + 1)))
		frame.append(contentsOf: [0, 0, 0x03]) // flags, then UTF-8 encoding
		frame.append(text)
		var tag = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00]) // "ID3", v2.4, no flags
		tag.append(syncsafe(UInt32(frame.count)))
		tag.append(frame)
		return tag
	}

	private static func syncsafe(_ value: UInt32) -> Data {
		Data([UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F), UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)])
	}

	func append(_ pcm: Data) {
		queue.async { [input] in
			try? input.fileHandleForWriting.write(contentsOf: pcm)
		}
	}

	func stop() {
		output.fileHandleForReading.readabilityHandler = nil
		try? input.fileHandleForWriting.close()
		if process.isRunning { process.terminate() }
		broadcaster.closeAll()
	}
}
