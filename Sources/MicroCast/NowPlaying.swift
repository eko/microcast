import AppKit
import CryptoKit
import Foundation
import os

/// The track Music or Spotify is playing, when that is what listeners hear.
struct NowPlaying: Equatable {
	let source: String
	let title: String
	let artist: String
	let album: String
	let trackID: String
	var artworkID: String?

	var json: [String: Any] {
		var object: [String: Any] = ["source": source, "title": title, "artist": artist, "album": album]
		if let artworkID { object["artwork"] = "/artwork?id=\(artworkID)" }
		return object
	}
}

/// Asks Music and Spotify what they play, through AppleScript, a few times a minute while streaming.
final class NowPlayingMonitor {
	struct Player {
		let name: String
		let bundleID: String
	}

	static let players = [Player(name: "Music", bundleID: "com.apple.Music"), Player(name: "Spotify", bundleID: "com.spotify.client")]

	private let queue = DispatchQueue(label: "local.microcast.nowplaying")
	private var timer: DispatchSourceTimer?
	private let state = OSAllocatedUnfairLock(initialState: (current: NowPlaying?.none, artwork: (id: "", data: Data(), type: "image/jpeg")))
	private let logger = Logger(subsystem: "local.microcast", category: "nowplaying")
	/// Which players may be shown right now, decided by the caller (source mode and settings).
	var allowed: () -> Set<String> = { [] }
	var onChange: (NowPlaying?) -> Void = { _ in }
	/// Every poll while a track plays: its id, the position in seconds and the duration in seconds.
	var onProgress: (_ trackID: String, _ position: Double, _ duration: Double) -> Void = { _, _, _ in }
	/// Seconds between polls; one second when jingles must land close to a track change.
	var interval: Double = 3

	var current: NowPlaying? { state.withLock { $0.current } }

	func artwork(id: String) -> (data: Data, type: String)? {
		state.withLock { $0.artwork.id == id && !$0.artwork.data.isEmpty ? ($0.artwork.data, $0.artwork.type) : nil }
	}

	private let frozen = OSAllocatedUnfairLock(initialState: false)

	/// Presets the track and its artwork and stops polling; for screenshots and tests.
	func preview(_ track: NowPlaying?, artwork: (data: Data, type: String)? = nil) {
		frozen.withLock { $0 = true }
		state.withLock {
			$0.current = track
			if let artwork, let id = track?.artworkID { $0.artwork = (id, artwork.data, artwork.type) }
		}
	}

	func start() {
		let timer = DispatchSource.makeTimerSource(queue: queue)
		timer.schedule(deadline: .now() + 1, repeating: interval)
		timer.setEventHandler { [weak self] in self?.poll() }
		timer.resume()
		self.timer = timer
	}

	func stop() {
		timer?.cancel()
		timer = nil
		update(nil)
	}

	private func poll() {
		if frozen.withLock({ $0 }) { return }
		let allowed = allowed()
		for player in Self.players where allowed.contains(player.bundleID) {
			guard !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty else { continue }
			// At a track boundary the player can answer nothing for an instant; ask again before concluding.
			var answer = Self.osascript(Self.trackScript(for: player.name)).flatMap { (Self.parseTrack($0, source: player.name), $0) }
			if answer?.0 == nil, current != nil {
				Thread.sleep(forTimeInterval: 0.25)
				answer = Self.osascript(Self.trackScript(for: player.name)).flatMap { (Self.parseTrack($0, source: player.name), $0) }
			}
			guard let (parsed, output) = answer, var track = parsed else { continue }
			if track.trackID != current?.trackID {
				track.artworkID = fetchArtwork(for: track, player: player)
			} else {
				track.artworkID = current?.artworkID
			}
			update(track)
			if let progress = Self.parseProgress(output, source: player.name) {
				onProgress(track.trackID, progress.position, progress.duration)
			}
			return
		}
		update(nil)
	}

	private func update(_ track: NowPlaying?) {
		let changed: Bool = state.withLock {
			guard $0.current != track else { return false }
			$0.current = track
			return true
		}
		if changed { onChange(track) }
	}

	/// Music hands artwork over as raw bytes; Spotify gives a URL. Either way it is cached under a hash.
	private func fetchArtwork(for track: NowPlaying, player: Player) -> String? {
		var data: Data?
		var type = "image/jpeg"
		if player.name == "Spotify" {
			if let output = Self.osascript("tell application \"Spotify\" to artwork url of current track"), let url = URL(string: output.trimmingCharacters(in: .whitespacesAndNewlines)) {
				data = try? Data(contentsOf: url)
			}
		} else if let output = Self.osascript("tell application \"Music\" to data of artwork 1 of current track") {
			(data, type) = Self.parseAppleScriptData(output)
		}
		guard let data, !data.isEmpty else { return nil }
		let id = Data(SHA256.hash(data: data)).prefix(8).map { String(format: "%02x", $0) }.joined()
		let artwork = (id: id, data: data, type: type)
		state.withLock { $0.artwork = artwork }
		return id
	}

	static func trackScript(for player: String) -> String {
		"""
		tell application "\(player)"
			if player state is not playing then return ""
			set t to current track
			set idText to ""
			try
				set idText to (persistent ID of t) as text
			on error
				set idText to (id of t) as text
			end try
			set posText to ""
			set durText to ""
			try
				set posText to (player position) as text
				set durText to (duration of t) as text
			end try
			return (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & idText & linefeed & posText & linefeed & durText
		end tell
		"""
	}

	/// Lines 5 and 6: position and duration. Spotify reports the duration in milliseconds.
	static func parseProgress(_ output: String, source: String) -> (position: Double, duration: Double)? {
		let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
		guard lines.count >= 6, let position = Double(lines[4].replacingOccurrences(of: ",", with: ".")),
			var duration = Double(lines[5].replacingOccurrences(of: ",", with: ".")), duration > 0 else { return nil }
		if source == "Spotify" { duration /= 1000 }
		return (position, duration)
	}

	/// "Title\\nArtist\\nAlbum\\nID" → track; empty output means nothing is playing.
	static func parseTrack(_ output: String, source: String) -> NowPlaying? {
		let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
		guard lines.count >= 4, !lines[0].isEmpty else { return nil }
		return NowPlaying(source: source, title: lines[0], artist: lines[1], album: lines[2], trackID: lines[3].isEmpty ? "\(lines[0])|\(lines[1])" : lines[3])
	}

	/// osascript prints binary as «data JPEGFFD8…»; the four letters name the type.
	static func parseAppleScriptData(_ output: String) -> (Data?, String) {
		guard let start = output.range(of: "«data "), let end = output.range(of: "»", range: start.upperBound..<output.endIndex) else { return (nil, "image/jpeg") }
		let body = output[start.upperBound..<end.lowerBound]
		let code = String(body.prefix(4))
		let hex = body.dropFirst(4)
		var bytes = [UInt8]()
		bytes.reserveCapacity(hex.count / 2)
		var index = hex.startIndex
		while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
			guard let byte = UInt8(hex[index..<next], radix: 16) else { return (nil, "image/jpeg") }
			bytes.append(byte)
			index = next
		}
		return (Data(bytes), code == "PNGf" ? "image/png" : code == "TIFF" ? "image/tiff" : "image/jpeg")
	}

	private static func osascript(_ script: String) -> String? {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
		process.arguments = ["-e", script]
		let output = Pipe()
		process.standardOutput = output
		process.standardError = FileHandle.nullDevice
		process.standardInput = FileHandle.nullDevice
		do { try process.run() } catch { return nil }
		let data = output.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		guard process.terminationStatus == 0 else { return nil }
		return String(decoding: data, as: UTF8.self)
	}
}
