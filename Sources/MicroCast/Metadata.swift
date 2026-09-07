import Foundation

/// Fills a title pattern with the current track. Placeholders: %name% %artist% %title% %album%.
enum TitleTemplate {
	static let defaultPattern = "%name% — %artist% - %title%"
	static let placeholders = ["%name%", "%artist%", "%title%", "%album%"]

	/// With no track playing, collapses to the station name so there are no empty "Now playing:  - " strings.
	static func render(_ pattern: String, name: String, track: NowPlaying?) -> String {
		let effective = pattern.trimmingCharacters(in: .whitespaces).isEmpty ? defaultPattern : pattern
		guard let track else { return name }
		return effective
			.replacingOccurrences(of: "%artist%", with: track.artist)
			.replacingOccurrences(of: "%title%", with: track.title)
			.replacingOccurrences(of: "%album%", with: track.album)
			.replacingOccurrences(of: "%name%", with: name)
	}
}

/// Shoutcast/Icecast in-stream metadata: the `StreamTitle` that VLC, mpv and foobar2000 show and update live.
enum ICY {
	static let metaInterval = 16_000

	/// A metadata block: one length byte (count of 16-byte units) then the NUL-padded `StreamTitle='…';`.
	static func metadataBlock(_ title: String) -> Data {
		let clean = String(title.replacingOccurrences(of: "'", with: "").prefix(3_800))
		var bytes = Array("StreamTitle='\(clean)';".utf8)
		let units = (bytes.count + 15) / 16
		bytes += Array(repeating: 0, count: units * 16 - bytes.count)
		return Data([UInt8(units)] + bytes)
	}

	/// The empty block sent at a boundary when the title has not changed.
	static let noChange = Data([0])

	/// The Shoutcast status line. VLC 3's default HTTP access never asks for metadata; it cannot parse this
	/// line, falls back to its legacy Shoutcast access, and *that* one requests and strips metadata properly.
	static let shoutcastStatusLine = "ICY 200 OK"

	/// Players known to handle the legacy Shoutcast reply. Browsers must never get it: it is not valid HTTP.
	static func needsShoutcastReply(userAgent: String?) -> Bool {
		guard let agent = userAgent?.lowercased() else { return false }
		return agent.contains("vlc") || agent.contains("libvlc")
	}
}

/// Splices ICY metadata into a byte stream at `metaint` boundaries, per connection.
struct ICYInterleaver {
	let metaint: Int
	private var remaining: Int
	private var lastTitle: String?

	init(metaint: Int = ICY.metaInterval) {
		self.metaint = metaint
		remaining = metaint
	}

	/// Returns `audio` with a metadata block inserted after every `metaint` bytes; the block carries the title
	/// only when it changed since the last one, otherwise a single zero byte.
	mutating func process(_ audio: Data, title: String) -> Data {
		var out = Data()
		var buffer = audio
		while buffer.count >= remaining {
			out.append(Data(buffer.prefix(remaining)))
			buffer = Data(buffer.dropFirst(remaining))
			if title != lastTitle {
				out.append(ICY.metadataBlock(title))
				lastTitle = title
			} else {
				out.append(ICY.noChange)
			}
			remaining = metaint
		}
		if !buffer.isEmpty {
			out.append(buffer)
			remaining -= buffer.count
		}
		return out
	}
}
