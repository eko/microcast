import AppKit
import AVFoundation
import Foundation
import Observation
import os

enum Settings {
	static var deviceUID: String { UserDefaults.standard.string(forKey: "deviceUID") ?? "" }
	/// "device" (an audio input) or "apps" (the output of running applications through a process tap).
	static var sourceMode: String { UserDefaults.standard.string(forKey: "sourceMode") ?? "device" }
	static var allApps: Bool { UserDefaults.standard.bool(forKey: "allApps") }
	static var mixInput: Bool { UserDefaults.standard.bool(forKey: "mixInput") }
	static var selectedApps: [String] {
		(UserDefaults.standard.string(forKey: "selectedApps") ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
	}
	static var autoStart: Bool { UserDefaults.standard.bool(forKey: "autoStart") }
	/// Keep the address (servers, tunnel, HTTPS) up between streams and serve the off-air page.
	static var keepOnline: Bool { isEnabled("keepOnline") }
	static var nowPlayingEnabled: Bool { isEnabled("nowPlayingEnabled") }
	static var jinglesEnabled: Bool { UserDefaults.standard.bool(forKey: "jinglesEnabled") }
	static var screenEnabled: Bool { UserDefaults.standard.bool(forKey: "screenEnabled") }
	static var screenDisplayID: CGDirectDisplayID { CGDirectDisplayID(UserDefaults.standard.integer(forKey: "screenDisplayID")) }
	static var screenFPS: Int { let v = UserDefaults.standard.integer(forKey: "screenFPS"); return v > 0 ? v : 12 }
	static var screenMaxWidth: Int { let v = UserDefaults.standard.integer(forKey: "screenMaxWidth"); return v > 0 ? v : 1280 }
	static var screenQuality: Double { let v = UserDefaults.standard.double(forKey: "screenQuality"); return v > 0 ? v : 0.7 }
	static var screenRegion: ScreenRegion {
		ScreenRegion(
			x: UserDefaults.standard.integer(forKey: "screenX"), y: UserDefaults.standard.integer(forKey: "screenY"),
			width: UserDefaults.standard.integer(forKey: "screenWidth"), height: UserDefaults.standard.integer(forKey: "screenHeight")
		)
	}
	/// 0 means the music stays at full level under the jingle.
	static var jingleDuckDecibels: Double {
		guard let value = UserDefaults.standard.object(forKey: "jingleDuckDecibels") as? Double else { return -12 }
		return min(0, max(-30, value))
	}
	/// Seconds before the end of the track at which the jingle starts; 0 means at the change.
	static var jingleLeadSeconds: Double {
		let value = UserDefaults.standard.object(forKey: "jingleLeadSeconds") as? Double
		return min(30, max(0, value ?? 2))
	}

	static var jingleVolume: Double {
		let value = UserDefaults.standard.double(forKey: "jingleVolume")
		return value > 0 ? value : 1
	}
	static var jingleFolder: URL {
		let custom = UserDefaults.standard.string(forKey: "jingleFolder") ?? ""
		return custom.isEmpty ? JingleBank.defaultFolder : URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
	}
	static var lastLive: Date? {
		let value = UserDefaults.standard.double(forKey: "lastLive")
		return value > 0 ? Date(timeIntervalSince1970: value) : nil
	}
	static var password: String { UserDefaults.standard.string(forKey: "password") ?? "" }

	/// Everything a running stream depends on, to tell when a restart is needed.
	struct Snapshot: Equatable {
		let deviceUID, streamName, password, tunnelProvider, cloudflareToken, cloudflareHostname, customTunnelCommand, recordFormat: String
		let recordFolder: URL
		let port: UInt16
		let partDuration, segmentDuration: Double
		let bitrates: [Int]
		let formats: [Bool]
		let sourceMode: String
		let allApps, mixInput: Bool
		let selectedApps: [String]
		let duck: [String]
	}

	static var snapshot: Snapshot {
		Snapshot(
			deviceUID: deviceUID, streamName: streamName, password: password, tunnelProvider: tunnelProvider,
			cloudflareToken: cloudflareToken, cloudflareHostname: cloudflareHostname, customTunnelCommand: customTunnelCommand,
			recordFormat: recordFormat, recordFolder: recordFolder, port: port, partDuration: partDuration, segmentDuration: segmentDuration,
			bitrates: bitrates, formats: [hlsEnabled, aacEnabled, mp3Enabled, flacEnabled, pcmEnabled],
			sourceMode: sourceMode, allApps: allApps, mixInput: mixInput, selectedApps: selectedApps,
			duck: [duckSubdomain, duckToken, duckHostname, ownHostname, acmeEmail, "\(duckPublicPort)", "\(httpsPort)", "\(httpsEnabled)"]
		)
	}

	static var streamName: String {
		let value = UserDefaults.standard.string(forKey: "streamName")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		return value.isEmpty ? "MicroCast" : value
	}
	static var tunnelProvider: String { UserDefaults.standard.string(forKey: "tunnelProvider") ?? "off" }
	static var cloudflareToken: String { UserDefaults.standard.string(forKey: "cloudflareToken") ?? "" }
	static var cloudflareHostname: String { UserDefaults.standard.string(forKey: "cloudflareHostname") ?? "" }
	static var customTunnelCommand: String { UserDefaults.standard.string(forKey: "customTunnelCommand") ?? "" }
	static var recordFormat: String { UserDefaults.standard.string(forKey: "recordFormat") ?? "off" }
	static var duckSubdomain: String { (UserDefaults.standard.string(forKey: "duckSubdomain") ?? "").trimmingCharacters(in: .whitespaces).lowercased() }
	static var duckToken: String { UserDefaults.standard.string(forKey: "duckToken") ?? "" }
	static var duckHostname: String { UserDefaults.standard.string(forKey: "duckHostname") ?? "" }
	static var ownHostname: String { (UserDefaults.standard.string(forKey: "ownHostname") ?? "").trimmingCharacters(in: .whitespaces).lowercased() }
	static var acmeEmail: String { UserDefaults.standard.string(forKey: "acmeEmail") ?? "" }
	static var httpsEnabled: Bool { isEnabled("httpsEnabled") }
	static var acmeStaging: Bool { UserDefaults.standard.bool(forKey: "acmeStaging") }

	static var duckPublicPort: Int {
		let value = UserDefaults.standard.integer(forKey: "duckPublicPort")
		return value > 0 && value < 65536 ? value : 443
	}

	static var httpsPort: UInt16 {
		let value = UserDefaults.standard.integer(forKey: "httpsPort")
		return value > 0 && value < 65536 ? UInt16(value) : 8443
	}

	static let defaultBitrates = [64, 128, 256, 320]
	static var bitrates: [Int] { parseBitrates(UserDefaults.standard.string(forKey: "bitrates") ?? "") }

	/// "64, 128, 256, 320" → sorted unique values clamped to what the AAC encoder accepts (64–320 kbps), at most eight.
	static func parseBitrates(_ text: String) -> [Int] {
		let values = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.map { min(320, max(64, $0)) }
		let unique = Array(Set(values)).sorted()
		return unique.isEmpty ? defaultBitrates : Array(unique.prefix(8))
	}

	/// Formats default to enabled; a stored false disables one.
	static func isEnabled(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
	static var hlsEnabled: Bool { isEnabled("enableHLS") }
	static var aacEnabled: Bool { isEnabled("enableAAC") }
	static var mp3Enabled: Bool { isEnabled("enableMP3") }
	static var flacEnabled: Bool { isEnabled("enableFLAC") }
	static var pcmEnabled: Bool { isEnabled("enablePCM") }

	static var recordFolder: URL {
		let custom = UserDefaults.standard.string(forKey: "recordFolder") ?? ""
		if !custom.isEmpty { return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath) }
		return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/MicroCast")
	}

	static var port: UInt16 {
		let value = UserDefaults.standard.integer(forKey: "port")
		return value > 0 && value < 65536 ? UInt16(value) : 8080
	}

	static var partDuration: Double {
		let value = UserDefaults.standard.double(forKey: "partDuration")
		return value > 0 ? value : 0.334
	}

	static var segmentDuration: Double {
		let value = UserDefaults.standard.double(forKey: "segmentDuration")
		return value > 0 ? value : 2
	}
}

/// Owns the whole pipeline: capture → encoders → HTTP server. Drives the menu bar UI.
@MainActor
@Observable
final class Streamer {
	private(set) var isRunning = false
	private(set) var isStarting = false
	/// Why the last start failed, until the next attempt.
	private(set) var failure: String?
	private(set) var statusMessage = "Not streaming"
	private(set) var deviceName = ""
	private(set) var startedAt: Date?
	private(set) var levelLeft: Float = 0
	private(set) var levelRight: Float = 0
	private(set) var peakLeft: Float = 0
	private(set) var peakRight: Float = 0
	/// True while live when a setting differs from the one the stream started with.
	private(set) var settingsChanged = false
	private(set) var listeners = 0
	private(set) var peakListeners = 0
	private(set) var listenerSamples: [ListenerHistory.Sample] = []
	private(set) var pageURLs: [URL] = []
	private(set) var tunnelURL: URL?
	private(set) var tunnelStatus = ""
	private(set) var recordingURL: URL?
	private(set) var recordingBytes: Int64 = 0
	/// Address reachable (servers and tunnel up), whether or not audio is streaming.
	private(set) var isOnline = false
	private(set) var nowPlaying: NowPlaying?
	/// Jingle files available for the manual button.
	private(set) var jingleCount = 0
	private(set) var jingleStatus = ""
	let lame = MP3Stream.findLame()

	private var capture: AudioSource?
	private var hls: [Int: HLSVariant] = [:]
	private var aac: [Int: AACStream] = [:]
	private var mp3: [Int: MP3Stream] = [:]
	private var flac: FLACStream?
	private var pcm: PCMStream?
	private var router: Router? { routes.current }
	private let routes = RouterHolder()
	private let nowPlayingMonitor = NowPlayingMonitor()
	private let mixer = AudioMixer()
	private var screenCapture: ScreenCapture?
	private(set) var screenStatus = "" 
	private var lastTrackID: String?
	private var lastJingle: URL?
	/// The track a jingle was already fired for (before its end), and the pending precise timer.
	private var jingledTrackID: String?
	private var lastPosition: Double = 0
	private var scheduledJingle: DispatchWorkItem?
	private var recorder: Recorder?
	private var server: HTTPServer?
	private var httpsServer: HTTPServer?
	private var onlineTask: Task<Void, Never>?
	private var duckDNS: DuckDNSPublisher?
	private let challenges = ACMEChallengeStore()
	private var tunnel: Tunnel?
	/// Shared with the router so the page can show the public address.
	private let publicURL = OSAllocatedUnfairLock<URL?>(initialState: nil)
	private var meter: Timer?
	private var sampler: Timer?
	private var history = ListenerHistory()
	private var activeSnapshot: Settings.Snapshot?
	private let logger = Logger(subsystem: "local.microcast", category: "streamer")

	var permissionDenied: Bool {
		let status = AVCaptureDevice.authorizationStatus(for: .audio)
		return status == .denied || status == .restricted
	}

	nonisolated var permissionScreenDenied: Bool { !ScreenPermission.granted }

	init() {
		deviceName = Self.describeSource()
		// Child processes (lame, cloudflared…) must not outlive the app.
		NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.stop() }
		}
		nowPlayingMonitor.allowed = { Self.allowedNowPlayingSources() }
		nowPlayingMonitor.onChange = { [weak self] track in Task { @MainActor in self?.trackDidChange(track) } }
		nowPlayingMonitor.onProgress = { [weak self] trackID, position, duration in
			Task { @MainActor in self?.trackDidProgress(trackID, position: position, duration: duration) }
		}
		if Settings.keepOnline || Settings.autoStart {
			Task {
				await goOnline()
				if Settings.autoStart { await start() }
			}
		}
	}

	func trackDidChange(_ track: NowPlaying?) {
		nowPlaying = track
		// A pause or a momentary blank at a boundary must not forget the previous track.
		defer { if let track { lastTrackID = track.trackID } }
		guard Settings.jinglesEnabled, isRunning, let track, let previous = lastTrackID, previous != track.trackID else { return }
		let pending = scheduledJingle != nil
		logger.info("track changed: \(previous, privacy: .public) → \(track.trackID, privacy: .public), jingled ahead: \(self.jingledTrackID == previous), pending: \(pending)")
		scheduledJingle?.cancel()
		scheduledJingle = nil
		// Played ahead of this change already; a still-pending one means the switch came early: play it now.
		guard pending || jingledTrackID != previous else { return }
		jingledTrackID = previous
		playJingle()
	}

	/// Fires the jingle `jingleLeadSeconds` before the track ends, timed from the last poll.
	func trackDidProgress(_ trackID: String, position: Double, duration: Double) {
		let lead = Settings.jingleLeadSeconds
		if position + 2 < lastPosition, jingledTrackID == trackID { jingledTrackID = nil } // rewound or repeating: allow again
		lastPosition = position
		guard Settings.jinglesEnabled, isRunning, lead > 0, jingledTrackID != trackID, scheduledJingle == nil else { return }
		guard let delay = JingleScheduler.delay(remaining: duration - position, lead: lead, interval: nowPlayingMonitor.interval) else { return }
		let work = DispatchWorkItem { [weak self] in
			Task { @MainActor in
				guard let self, self.scheduledJingle != nil else { return }
				self.scheduledJingle = nil
				self.jingledTrackID = trackID
				self.playJingle()
			}
		}
		scheduledJingle = work
		DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
		logger.info("jingle in \(delay, format: .fixed(precision: 2)) s, \(lead) s before the end")
	}

	/// Plays a random jingle from the bank over the ducked programme; also behind the panel's button.
	func playJingle() {
		guard isRunning else { return }
		let bank = JingleBank(folder: Settings.jingleFolder)
		guard let file = bank.pick(avoiding: lastJingle) else {
			jingleStatus = "No jingle files in \(Settings.jingleFolder.path)"
			logger.info("jingle: no files in \(Settings.jingleFolder.path, privacy: .public)")
			return
		}
		lastJingle = file
		mixer.configure(duckDecibels: Settings.jingleDuckDecibels, jingleVolume: Settings.jingleVolume)
		Task.detached { [mixer, logger] in
			do {
				let samples = try JingleBank.decode(file)
				if mixer.play(samples) {
					logger.info("jingle \(file.lastPathComponent, privacy: .public)")
				} else {
					logger.info("jingle skipped: one is still playing")
				}
			} catch {
				logger.error("jingle: \(error.localizedDescription)")
			}
		}
	}

	/// Music and Spotify count only when they are what listeners hear.
	nonisolated static func allowedNowPlayingSources() -> Set<String> {
		let players = Set(NowPlayingMonitor.players.map(\.bundleID))
		if Settings.sourceMode == "apps" {
			return Settings.allApps ? players : players.intersection(Settings.selectedApps)
		}
		return Settings.nowPlayingEnabled ? players : []
	}

	/// After start(), seeds the running stream with a demo track and listener history for page screenshots.
	func applyPreview() {
		let icon = Bundle.main.url(forResource: "icon", withExtension: "png").flatMap { try? Data(contentsOf: $0) } ?? Data()
		let track = NowPlaying(source: "Music", title: "Redbone", artist: "Childish Gambino", album: "\"Awaken, My Love!\"", trackID: "preview", artworkID: icon.isEmpty ? nil : "cover")
		nowPlayingMonitor.preview(track, artwork: icon.isEmpty ? nil : (icon, "image/png"))
		nowPlaying = track
		let now = Date()
		let shape = [0, 1, 1, 2, 3, 3, 5, 6, 6, 8, 10, 9, 11, 13, 12, 14, 16, 15, 17, 16, 15, 14]
		for (index, count) in shape.enumerated() { history.record(count, at: now.addingTimeInterval(Double(index - shape.count) * 5)) }
		listenerSamples = history.recent(seconds: 1800)
		peakListeners = history.peak
	}

	/// Fills the menu with representative content for screenshots and SwiftUI previews; touches no audio.
	func loadPreview() {
		deviceName = "Wave Link Stream"
		isOnline = true
		isRunning = true
		startedAt = Date().addingTimeInterval(-1_543)
		listeners = 12
		peakListeners = 18
		jingleCount = 3
		nowPlaying = NowPlaying(source: "Music", title: "Redbone", artist: "Childish Gambino", album: "\"Awaken, My Love!\"", trackID: "preview")
		levelLeft = 0.62
		levelRight = 0.54
		peakLeft = 0.85
		peakRight = 0.78
		tunnelURL = URL(string: "https://cast.example.com/")
		pageURLs = [URL(string: "http://studio.local:8080/")!, URL(string: "http://192.168.1.42:8080/")!]
		let now = Date()
		let shape = [0, 1, 1, 2, 3, 3, 5, 6, 6, 8, 10, 9, 11, 13, 12, 14, 16, 15, 17, 16, 15, 14, 13, 12]
		listenerSamples = shape.enumerated().map { index, count in
			ListenerHistory.Sample(time: now.addingTimeInterval(Double(index - shape.count) * 10), count: count)
		}
	}

	/// Brings the address up: HTTP listener, Bonjour, tunnel or DNS/HTTPS publisher, with the off-air page.
	/// Concurrent callers (launch and an early Start) share one attempt.
	func goOnline() async {
		guard !isOnline else { return }
		if let onlineTask {
			await onlineTask.value
			return
		}
		let task = Task { await bringOnline() }
		onlineTask = task
		await task.value
		onlineTask = nil
	}

	private func bringOnline() async {
		guard !isOnline else { return }
		let port = Settings.port
		routes.current = Router.offAir(name: Settings.streamName, password: Settings.password, publicURL: publicURL, challenges: challenges, lastLive: Settings.lastLive)
		do {
			let routes = routes
			let server = try HTTPServer(port: port, serviceName: Settings.streamName) { request in await routes.current!.handle(request) }
			try await server.start()
			self.server = server
		} catch {
			fail("Could not listen on port \(port): \(error.localizedDescription)")
			return
		}
		isOnline = true
		pageURLs = Self.pageURLs(port: port)
		statusMessage = "Online, off air"
		startTunnel(port: port)
	}

	/// Takes the address down: tunnel, listeners, Bonjour. Stops the stream first if needed.
	func goOffline() {
		if isRunning { stop(keepOnline: false) }
		tunnel?.stop()
		tunnel = nil
		duckDNS?.stop()
		duckDNS = nil
		httpsServer?.stop()
		httpsServer = nil
		server?.stop()
		server = nil
		tunnelURL = nil
		tunnelStatus = ""
		publicURL.withLock { $0 = nil }
		routes.current = nil
		pageURLs = []
		isOnline = false
		statusMessage = "Offline"
	}

	func start() async {
		guard !isRunning, !isStarting else { return }
		isStarting = true
		failure = nil
		statusMessage = "Starting…"
		defer { isStarting = false }
		let capturingApps = Settings.sourceMode == "apps"
		if !capturingApps || Settings.mixInput {
			guard await AVCaptureDevice.requestAccess(for: .audio) else {
				fail("Microphone access denied: allow MicroCast under System Settings → Privacy & Security → Microphone")
				return
			}
		}
		if capturingApps {
			guard await SystemAudioPermission.request() else {
				fail("System audio recording denied: allow MicroCast under System Settings → Privacy & Security → Screen & System Audio Recording")
				return
			}
		}
		guard let device = AudioDevices.device(uid: Settings.deviceUID) ?? AudioDevices.preferredInput() else {
			fail("No audio input device found")
			return
		}
		do {
			try await launch(device: device)
		} catch {
			logger.error("start failed: \(error.localizedDescription)")
			stop()
			fail("Could not start: \(error.localizedDescription)")
		}
	}

	func restart() async {
		goOffline()
		await start()
	}

	private func fail(_ message: String) {
		failure = message
		statusMessage = message
	}

	/// Ends the audio session; the address stays up (off-air page) unless `keepOnline` is false.
	func stop(keepOnline: Bool = Settings.keepOnline) {
		meter?.invalidate()
		meter = nil
		sampler?.invalidate()
		sampler = nil
		nowPlayingMonitor.stop()
		nowPlaying = nil
		scheduledJingle?.cancel()
		scheduledJingle = nil
		jingledTrackID = nil
		capture?.stop()
		capture = nil
		if isRunning {
			UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastLive")
		}
		hls.values.forEach { $0.stop() }
		hls = [:]
		mp3.values.forEach { $0.stop() }
		mp3 = [:]
		aac.values.forEach { $0.broadcaster.closeAll() }
		aac = [:]
		flac?.broadcaster.closeAll()
		flac = nil
		pcm?.broadcaster.closeAll()
		pcm = nil
		recorder?.stop()
		recorder = nil
		recordingURL = nil
		recordingBytes = 0
		if isOnline {
			routes.current = Router.offAir(name: Settings.streamName, password: Settings.password, publicURL: publicURL, challenges: challenges, lastLive: Settings.lastLive)
			statusMessage = "Online, off air"
		}
		isRunning = false
		deviceName = Self.describeSource()
		startedAt = nil
		activeSnapshot = nil
		settingsChanged = false
		levelLeft = 0
		levelRight = 0
		peakLeft = 0
		peakRight = 0
		listeners = 0
		if !keepOnline { goOffline() }
	}

	private func launch(device: AVCaptureDevice) async throws {
		let partDuration = Settings.partDuration
		let segmentDuration = Settings.segmentDuration
		let port = Settings.port
		let name = Settings.streamName
		let bitrates = Settings.bitrates

		for bitrate in bitrates {
			if Settings.hlsEnabled {
				hls[bitrate] = HLSVariant(bitrate: bitrate, partDuration: partDuration, segmentDuration: segmentDuration, title: name)
			}
			if Settings.aacEnabled {
				aac[bitrate] = try AACStream(bitrate: bitrate)
			}
			if Settings.mp3Enabled, let lame {
				mp3[bitrate] = try MP3Stream(lame: lame, bitrate: bitrate, title: name)
			}
		}
		let flac = Settings.flacEnabled ? try FLACStream(title: name) : nil
		self.flac = flac
		let pcm = Settings.pcmEnabled ? PCMStream() : nil
		self.pcm = pcm

		let hls = hls, aac = aac, mp3 = mp3
		mixer.output = { sampleBuffer, samples in
			for variant in hls.values { variant.append(sampleBuffer) }
			for stream in aac.values { stream.append(samples) }
			for stream in mp3.values { stream.append(samples) }
			flac?.append(samples)
			pcm?.append(samples)
		}
		mixer.configure(duckDecibels: Settings.jingleDuckDecibels, jingleVolume: Settings.jingleVolume)
		let mixer = mixer
		let sink: (Data) -> Void = { samples in mixer.append(samples) }
		jingleCount = JingleBank(folder: Settings.jingleFolder).files.count
		lastTrackID = nil
		let capture: AudioSource
		let sourceName: String
		if Settings.sourceMode == "apps" {
			let running = AudioApp.running()
			let selected = running.filter { Settings.selectedApps.contains($0.id) }
			guard Settings.allApps || !selected.isEmpty else { throw TapError.noSelection }
			capture = try TapCapture(
				target: Settings.allApps ? .all : .apps(selected),
				mixInputDeviceUID: Settings.mixInput ? device.uniqueID : nil,
				sink: sink
			)
			var parts = Settings.allApps ? ["All applications"] : selected.map(\.name)
			if Settings.mixInput { parts.append(device.localizedName) }
			sourceName = parts.joined(separator: " + ")
		} else {
			capture = try AudioCapture(device: device, sink: sink)
			sourceName = device.localizedName
		}
		self.capture = capture

		history = ListenerHistory()
		listenerSamples = []
		peakListeners = 0
		if !isOnline {
			await goOnline()
			guard isOnline else { throw HTTPServerError.invalidPort }
		}
		let screen = makeScreenCapture()
		screenCapture = screen as? ScreenCapture
		routes.current = Router(
			hls: hls, aac: aac, mp3: mp3, flac: flac, pcm: pcm, bitrates: bitrates, history: history, challenges: challenges,
			nowPlaying: nowPlayingMonitor, screen: screen, name: name, partDuration: partDuration,
			password: Settings.password, publicURL: publicURL
		)
		_ = port
		nowPlayingMonitor.interval = Settings.jinglesEnabled ? 1 : 3
		nowPlayingMonitor.start()
		startRecording(name: name)
		startScreenCapture()

		Task.detached { capture.start() }
		isRunning = true
		startedAt = Date()
		deviceName = sourceName
		activeSnapshot = Settings.snapshot
		pageURLs = Self.pageURLs(port: port)
		statusMessage = "Streaming \(sourceName)"
		logger.info("streaming \(sourceName) on port \(port)")
		meter = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
			Task { @MainActor in self?.refreshMeters() }
		}
		sampleListeners()
		sampler = Timer.scheduledTimer(withTimeInterval: ListenerHistory.interval, repeats: true) { [weak self] _ in
			Task { @MainActor in self?.sampleListeners() }
		}
	}

	/// What the popover shows before streaming starts.
	nonisolated static func describeSource() -> String {
		if Settings.sourceMode == "apps" {
			if Settings.allApps { return "All applications" }
			let names = AudioApp.running().filter { Settings.selectedApps.contains($0.id) }.map(\.name)
			return names.isEmpty ? "Applications" : names.joined(separator: ", ")
		}
		return AudioDevices.device(uid: Settings.deviceUID)?.localizedName ?? AudioDevices.preferredInput()?.localizedName ?? ""
	}

	private func startTunnel(port: UInt16) {
		let provider = Tunnel.Provider(rawValue: Settings.tunnelProvider) ?? .off
		guard provider != .off else { return }
		if provider == .duckdns || provider == .ownHost {
			startPublisher(provider)
			return
		}
		do {
			let tunnel = try Tunnel(configuration: Tunnel.Configuration(
				provider: provider, port: port,
				cloudflareToken: Settings.cloudflareToken,
				cloudflareHostname: Settings.cloudflareHostname,
				customCommand: Settings.customTunnelCommand
			))
			try tunnel.start(
				onURL: { [weak self] url in Task { @MainActor in self?.tunnelDidPublish(url) } },
				onExit: { [weak self, weak tunnel] status in
					let output = tunnel?.recentOutput ?? ""
					Task { @MainActor in self?.tunnelDidExit(status, output: output) }
				}
			)
			self.tunnel = tunnel
			tunnelStatus = "\(provider.label): connecting…"
		} catch {
			tunnelStatus = "Tunnel not started: \(error.localizedDescription)"
			logger.error("tunnel: \(error.localizedDescription)")
		}
	}

	/// Port-forwarding modes: DuckDNS or the router's own DynDNS name; with HTTPS on, a second listener serves
	/// TLS once the certificate exists.
	private func startPublisher(_ provider: Tunnel.Provider) {
		let mode: DuckDNSPublisher.Mode
		if provider == .duckdns {
			guard !Settings.duckSubdomain.isEmpty, !Settings.duckToken.isEmpty else {
				tunnelStatus = "DuckDNS needs a subdomain and a token (Settings → Internet)"
				return
			}
			mode = .duckdns(subdomain: Settings.duckSubdomain, token: Settings.duckToken, customHostname: Settings.duckHostname)
		} else {
			guard !Settings.ownHostname.isEmpty else {
				tunnelStatus = "Enter your hostname in Settings → Internet"
				return
			}
			mode = .hostname(Settings.ownHostname)
		}
		let publisher = DuckDNSPublisher(configuration: DuckDNSPublisher.Configuration(
			mode: mode, publicPort: Settings.duckPublicPort, https: Settings.httpsEnabled, email: Settings.acmeEmail, staging: Settings.acmeStaging
		), challenges: challenges)
		duckDNS = publisher
		tunnelStatus = "Preparing the public address…"
		let httpsPort = Settings.httpsPort
		publisher.start(
			onStatus: { [weak self] status in Task { @MainActor in self?.tunnelStatus = status.hasSuffix("…") ? status : status + "…" } },
			onIdentity: { [weak self] identity in Task { @MainActor in self?.startHTTPS(identity: identity, port: httpsPort) } },
			onReady: { [weak self] url in Task { @MainActor in self?.tunnelDidPublish(url) } },
			onFailure: { [weak self] message in Task { @MainActor in self?.tunnelStatus = message; self?.logger.error("duckdns: \(message)") } }
		)
	}

	private func startHTTPS(identity: SecIdentity, port: UInt16) {
		httpsServer?.stop()
		do {
			let routes = routes
			let server = try HTTPServer(port: port, identity: identity) { request in await routes.current!.handle(request) }
			Task { @MainActor in
				do {
					try await server.start()
					httpsServer = server
					logger.info("HTTPS on port \(port)")
				} catch {
					tunnelStatus = "HTTPS could not start on port \(port): \(error.localizedDescription)"
				}
			}
		} catch {
			tunnelStatus = "HTTPS could not start: \(error.localizedDescription)"
		}
	}

	private func tunnelDidPublish(_ url: URL) {
		tunnelURL = url
		publicURL.withLock { $0 = url }
		tunnelStatus = ""
		logger.info("public URL \(url.absoluteString)")
	}

	private func tunnelDidExit(_ status: Int32, output: String) {
		guard isRunning, tunnel != nil else { return }
		tunnel = nil
		tunnelURL = nil
		publicURL.withLock { $0 = nil }
		let lastLine = output.split(separator: "\n").last.map(String.init) ?? ""
		tunnelStatus = "Tunnel exited (code \(status)). \(lastLine)"
		logger.error("tunnel exited \(status): \(lastLine)")
	}

	/// Screen capture is optional and independent of the audio source; served as MJPEG at /screen.mjpeg.
	private var demoScreen: DemoScreenSource?

	private func makeScreenCapture() -> ScreenSource? {
		if UserDefaults.standard.bool(forKey: "screenDemo") {
			let demo = DemoScreenSource(); demo.start(); demoScreen = demo; return demo
		}
		guard Settings.screenEnabled else { return nil }
		guard ScreenPermission.request() else {
			screenStatus = "Screen Recording denied (System Settings → Privacy & Security → Screen Recording)"
			return nil
		}
		return ScreenCapture(
			displayID: Settings.screenDisplayID, region: Settings.screenRegion,
			fps: Settings.screenFPS, maxWidth: Settings.screenMaxWidth, quality: Settings.screenQuality
		)
	}

	private func startScreenCapture() {
		guard let capture = screenCapture else { return }
		Task { @MainActor in
			do { try await capture.start() } catch {
				screenStatus = "Screen capture failed: \(error.localizedDescription)"
				logger.error("screen: \(error.localizedDescription)")
			}
		}
	}

	private func startRecording(name: String) {
		let format = Settings.recordFormat
		let source: (Broadcaster, String)?
		switch format {
		case "flac": source = flac.map { ($0.broadcaster, "flac") }
		case "aac": source = aac.keys.max().flatMap { aac[$0] }.map { ($0.broadcaster, "aac") }
		case "mp3": source = mp3.keys.max().flatMap { mp3[$0] }.map { ($0.broadcaster, "mp3") }
		default: return
		}
		guard let (broadcaster, fileExtension) = source else {
			statusMessage = "Not recording: \(format.uppercased()) is disabled in Settings → Stream"
			return
		}
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
		let safeName = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
		let file = Settings.recordFolder.appendingPathComponent("\(safeName) \(formatter.string(from: Date())).\(fileExtension)")
		do {
			recorder = try Recorder(stream: broadcaster.subscribe(), url: file)
			recordingURL = file
		} catch {
			statusMessage = "Recording failed: \(error.localizedDescription)"
			logger.error("recording: \(error.localizedDescription)")
		}
	}

	private func sampleListeners() {
		history.record(router?.listenerCount ?? 0)
		listenerSamples = history.recent(seconds: 1800)
		peakListeners = history.peak
	}

	private func refreshMeters() {
		let levels = capture?.levels ?? (left: 0, right: 0)
		levelLeft = levels.left
		levelRight = levels.right
		peakLeft = max(levels.left, peakLeft - 0.015)
		peakRight = max(levels.right, peakRight - 0.015)
		listeners = router?.listenerCount ?? 0
		recordingBytes = recorder?.bytesWritten ?? 0
		settingsChanged = activeSnapshot.map { $0 != Settings.snapshot } ?? false
	}

	/// localhost, the Bonjour host name, then every IPv4 address of this Mac.
	nonisolated static func pageURLs(port: UInt16) -> [URL] {
		var urls = [URL(string: "http://localhost:\(port)/")!]
		if let local = Host.current().names.first(where: { $0.hasSuffix(".local") }), let url = URL(string: "http://\(local):\(port)/") {
			urls.append(url)
		}
		var list: UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&list) == 0, let first = list else { return urls }
		defer { freeifaddrs(list) }
		for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
			let interface = pointer.pointee
			guard let address = interface.ifa_addr,
				address.pointee.sa_family == UInt8(AF_INET),
				interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
				interface.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
			var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
			guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0,
				let url = URL(string: "http://\(String(cString: host)):\(port)/") else { continue }
			urls.append(url)
		}
		return urls
	}
}


/// The router the listeners currently hit: the live one while streaming, the off-air one in between.
final class RouterHolder: @unchecked Sendable {
	private let lock = NSLock()
	private var router: Router?

	var current: Router? {
		get { lock.withLock { router } }
		set { lock.withLock { router = newValue } }
	}
}
