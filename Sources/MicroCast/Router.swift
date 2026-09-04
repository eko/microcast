import Foundation
import os

/// HLS clients only poll, so count the addresses seen in the last few seconds.
final class ListenerTracker {
	private let lock = NSLock()
	private var lastSeen: [String: Date] = [:]
	private let window: TimeInterval = 12

	func touch(_ address: String) {
		lock.withLock { lastSeen[address] = Date() }
	}

	var activeCount: Int {
		lock.withLock {
			let cutoff = Date().addingTimeInterval(-window)
			lastSeen = lastSeen.filter { $0.value > cutoff }
			return lastSeen.count
		}
	}
}

/// Maps URLs to the live streams.
final class Router {
	private let hls: [Int: HLSVariant]
	private let aac: [Int: AACStream]
	private let mp3: [Int: MP3Stream]
	private let flac: FLACStream?
	private let pcm: PCMStream?
	private let bitrates: [Int]
	private let history: ListenerHistory
	private let challenges: ACMEChallengeStore
	private let nowPlaying: NowPlayingMonitor?
	private let live: Bool
	private let lastLive: Date?
	private let hlsListeners = ListenerTracker()
	private let name: String
	private let partDuration: Double
	private let password: String
	private let publicURL: OSAllocatedUnfairLock<URL?>
	private let page: Data
	private let script: Data?
	private let icon: Data?

	init(
		hls: [Int: HLSVariant],
		aac: [Int: AACStream],
		mp3: [Int: MP3Stream],
		flac: FLACStream?,
		pcm: PCMStream?,
		bitrates: [Int],
		history: ListenerHistory,
		challenges: ACMEChallengeStore,
		nowPlaying: NowPlayingMonitor? = nil,
		live: Bool = true,
		lastLive: Date? = nil,
		name: String,
		partDuration: Double,
		password: String,
		publicURL: OSAllocatedUnfairLock<URL?>
	) {
		self.hls = hls
		self.aac = aac
		self.mp3 = mp3
		self.flac = flac
		self.pcm = pcm
		self.bitrates = bitrates
		self.history = history
		self.challenges = challenges
		self.nowPlaying = nowPlaying
		self.live = live
		self.lastLive = lastLive
		self.name = name
		self.partDuration = partDuration
		self.password = password
		self.publicURL = publicURL
		let template = Bundle.main.url(forResource: "index", withExtension: "html").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
			?? "MicroCast: index.html is missing from the app bundle"
		let escaped = name.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
		page = Data(template
			.replacingOccurrences(of: "<title>MicroCast</title>", with: "<title>\(escaped)</title>")
			.replacingOccurrences(of: "<h1>MicroCast</h1>", with: "<h1>\(escaped)</h1>")
			.utf8)
		script = Bundle.main.url(forResource: "hls.min", withExtension: "js").flatMap { try? Data(contentsOf: $0) }
		icon = Bundle.main.url(forResource: "icon", withExtension: "png").flatMap { try? Data(contentsOf: $0) }
	}

	/// What the address serves between streams: the page in its off-air state, status, assets, challenges.
	static func offAir(name: String, password: String, publicURL: OSAllocatedUnfairLock<URL?>, challenges: ACMEChallengeStore, lastLive: Date?) -> Router {
		Router(
			hls: [:], aac: [:], mp3: [:], flac: nil, pcm: nil, bitrates: Settings.bitrates, history: ListenerHistory(), challenges: challenges,
			live: false, lastLive: lastLive, name: name, partDuration: Settings.partDuration, password: password, publicURL: publicURL
		)
	}

	/// People listening right now: open direct streams plus HLS players that polled recently.
	var listenerCount: Int {
		hlsListeners.activeCount
			+ aac.values.reduce(0) { $0 + $1.broadcaster.clientCount }
			+ mp3.values.reduce(0) { $0 + $1.broadcaster.clientCount }
			+ (flac?.broadcaster.clientCount ?? 0)
			+ (pcm?.broadcaster.clientCount ?? 0)
	}

	func handle(_ request: HTTPRequest) async -> HTTPResponse {
		guard request.method == "GET" || request.method == "HEAD" else { return .text(405, "method not allowed") }
		if request.path.hasPrefix("/.well-known/acme-challenge/") {
			let token = String(request.path.dropFirst("/.well-known/acme-challenge/".count))
			guard let answer = challenges.answer(for: token) else { return .text(404, "unknown challenge") }
			return HTTPResponse(contentType: "text/plain", headers: ["Cache-Control": "no-store"], body: .data(Data(answer.utf8)))
		}
		guard password.isEmpty || Self.authorized(request, password: password) else {
			return HTTPResponse(
				status: 401,
				headers: ["WWW-Authenticate": "Basic realm=\"MicroCast\", charset=\"UTF-8\"", "Cache-Control": "no-store"],
				body: .data(Data("password required".utf8))
			)
		}
		switch request.path {
		case "/", "/index.html":
			return .data(page, type: "text/html; charset=utf-8")
		case "/hls.min.js":
			return script.map { .data($0, type: "application/javascript", cache: "max-age=86400") } ?? .text(404, "hls.js is not bundled")
		case "/status.json":
			return .data(statusJSON(), type: "application/json")
		case "/artwork":
			guard let id = request.query["id"], let artwork = nowPlaying?.artwork(id: id) else { return .text(404, "no artwork") }
			return .data(artwork.data, type: artwork.type, cache: "max-age=86400")
		case "/icon.png", "/apple-touch-icon.png", "/favicon.ico":
			return icon.map { .data($0, type: "image/png", cache: "max-age=86400") } ?? .text(404, "no icon")
		case "/manifest.webmanifest":
			return .data(manifest(), type: "application/manifest+json")
		case "/hls/master.m3u8":
			guard live else { break }
			guard !hls.isEmpty else { return .text(404, "HLS is disabled") }
			return .data(Data(masterPlaylist().utf8), type: "application/vnd.apple.mpegurl")
		case "/stream.flac":
			guard live else { break }
			guard let flac else { return .text(404, "FLAC is disabled") }
			return .stream(flac.broadcaster.subscribe(), type: "audio/flac", headers: icyHeaders)
		case "/stream.pcm":
			guard live else { break }
			guard let pcm else { return .text(404, "PCM is disabled") }
			return .stream(pcm.broadcaster.subscribe(), type: "application/octet-stream", headers: [
				"X-Sample-Rate": String(AudioCapture.sampleRate),
				"X-Channels": String(AudioCapture.channels),
				"X-Bits-Per-Sample": "16",
			])
		default:
			break
		}
		guard live else {
			return HTTPResponse(status: 503, headers: ["Retry-After": "30", "Cache-Control": "no-store"], body: .data(Data("off air".utf8)))
		}
		if request.path.hasPrefix("/hls/") { return await hlsResponse(for: request) }
		if let (bitrate, format) = Self.progressive(path: request.path) {
			switch format {
			case "aac":
				if let stream = aac[bitrate] { return .stream(stream.broadcaster.subscribe(), type: "audio/aac", headers: icyHeaders(bitrate)) }
			case "mp3":
				if let stream = mp3[bitrate] { return .stream(stream.broadcaster.subscribe(), type: "audio/mpeg", headers: icyHeaders(bitrate)) }
			default:
				break
			}
		}
		return .text(404, "not found")
	}

	/// Shoutcast-style headers: VLC, mpv and foobar2000 show icy-name as the stream title.
	private var icyHeaders: [String: String] {
		["icy-name": name.replacingOccurrences(of: "\n", with: " "), "icy-pub": "0"]
	}

	private func icyHeaders(_ bitrate: Int) -> [String: String] {
		var headers = icyHeaders
		headers["icy-br"] = String(bitrate)
		return headers
	}

	/// HTTP Basic: any user name, the configured password.
	static func authorized(_ request: HTTPRequest, password: String) -> Bool {
		guard let header = request.headers["authorization"], header.lowercased().hasPrefix("basic "),
			let decoded = Data(base64Encoded: String(header.dropFirst(6)).trimmingCharacters(in: .whitespaces)),
			let credentials = String(data: decoded, encoding: .utf8) else { return false }
		let supplied = credentials.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? ""
		return supplied == password
	}

	/// "/stream-128.mp3" → (128, "mp3")
	private static func progressive(path: String) -> (Int, String)? {
		guard path.hasPrefix("/stream-") else { return nil }
		let rest = path.dropFirst("/stream-".count).split(separator: ".")
		guard rest.count == 2, let bitrate = Int(rest[0]) else { return nil }
		return (bitrate, String(rest[1]))
	}

	private func hlsResponse(for request: HTTPRequest) async -> HTTPResponse {
		let components = request.path.split(separator: "/")
		guard components.count == 3, let bitrate = Int(components[1]), let variant = hls[bitrate] else {
			return .text(404, "no such rendition")
		}
		let playlist = variant.playlist
		let timeout = Double(playlist.targetDuration) * 3
		let file = String(components[2])
		let segmentType = "audio/mp4"

		if file == "stream.m3u8" {
			hlsListeners.touch(request.remoteAddress)
			if let sequence = request.query["_HLS_msn"].flatMap({ Int($0) }) {
				await playlist.wait(forSequence: sequence, part: request.query["_HLS_part"].flatMap { Int($0) }, timeout: timeout)
			} else if !playlist.hasContent {
				await playlist.wait(forSequence: 0, part: 0, timeout: 10)
			}
			guard playlist.hasContent else { return .text(503, "stream is warming up") }
			return .data(Data(playlist.render().utf8), type: "application/vnd.apple.mpegurl")
		}
		if file == "init.mp4" {
			guard let data = playlist.initialization else { return .text(404, "no init segment yet") }
			return .data(data, type: segmentType, cache: "max-age=3600")
		}
		guard file.hasPrefix("seg"), file.hasSuffix(".m4s") else { return .text(404, "not found") }
		let numbers = file.dropFirst(3).dropLast(4).split(separator: ".").compactMap { Int($0) }
		switch numbers.count {
		case 1:
			await playlist.wait(forSequence: numbers[0], part: nil, timeout: timeout)
			guard let data = playlist.segment(sequence: numbers[0]) else { return .text(404, "segment gone") }
			return .data(data, type: segmentType, cache: "max-age=60")
		case 2:
			await playlist.wait(forSequence: numbers[0], part: numbers[1], timeout: timeout)
			guard let data = playlist.part(sequence: numbers[0], index: numbers[1]) else { return .text(404, "part gone") }
			return .data(data, type: segmentType, cache: "max-age=60")
		default:
			return .text(404, "not found")
		}
	}

	private func masterPlaylist() -> String {
		var lines = [
			"#EXTM3U",
			"#EXT-X-VERSION:6",
			"#EXT-X-INDEPENDENT-SEGMENTS",
			"#EXT-X-SESSION-DATA:DATA-ID=\"com.microcast.title\",VALUE=\"\(name.replacingOccurrences(of: "\"", with: "'"))\"",
		]
		for bitrate in hls.keys.sorted(by: >) {
			lines.append("#EXT-X-STREAM-INF:BANDWIDTH=\(bitrate * 1000 + 24_000),AVERAGE-BANDWIDTH=\(bitrate * 1000 + 8_000),CODECS=\"mp4a.40.2\"")
			lines.append("\(bitrate)/stream.m3u8")
		}
		return lines.joined(separator: "\n") + "\n"
	}

	/// Lets phones add the page to their home screen as a standalone app with the stream's name.
	private func manifest() -> Data {
		let manifest: [String: Any] = [
			"name": name,
			"short_name": String(name.prefix(12)),
			"start_url": "/",
			"display": "standalone",
			"background_color": "#0d0f13",
			"theme_color": "#2f6df6",
			"icons": [["src": "/icon.png", "sizes": "256x256", "type": "image/png"]],
		]
		return (try? JSONSerialization.data(withJSONObject: manifest)) ?? Data("{}".utf8)
	}

	private func statusJSON() -> Data {
		var status: [String: Any] = [
			"name": name,
			"live": live,
			"listeners": listenerCount,
			"peak": history.peak,
			"history": history.jsonRows(seconds: 1800),
			"historyInterval": ListenerHistory.interval,
			"bitrates": bitrates,
			"hls": !hls.isEmpty,
			"aac": !aac.isEmpty,
			"mp3": !mp3.isEmpty,
			"flac": flac != nil,
			"pcm": pcm != nil,
			"partDurationMs": Int((partDuration * 1000).rounded()),
			"protected": !password.isEmpty,
		]
		if let url = publicURL.withLock({ $0 }) { status["publicURL"] = url.absoluteString }
		if let lastLive { status["lastLive"] = lastLive.timeIntervalSince1970.rounded() }
		if let track = nowPlaying?.current { status["nowPlaying"] = track.json }
		return (try? JSONSerialization.data(withJSONObject: status)) ?? Data("{}".utf8)
	}
}
