import AVFoundation
import ServiceManagement
import SwiftUI

struct SettingsView: View {
	enum Tab: String, CaseIterable, Identifiable {
		case general, stream, screen, jingles, internet, recording, about

		var id: String { rawValue }

		var label: String {
			switch self {
			case .general: "General"
			case .stream: "Stream"
			case .screen: "Screen"
			case .jingles: "Jingles"
			case .internet: "Internet"
			case .recording: "Recording"
			case .about: "About"
			}
		}

		var symbol: String {
			switch self {
			case .general: "gearshape"
			case .stream: "waveform"
			case .screen: "rectangle.inset.filled.and.person.filled"
			case .jingles: "music.quarternote.3"
			case .internet: "globe"
			case .recording: "record.circle"
			case .about: "info.circle"
			}
		}
	}

	var streamer: Streamer
	@State private var tab: Tab

	init(streamer: Streamer, tab: Tab = .general) {
		self.streamer = streamer
		_tab = State(initialValue: tab)
	}

	var body: some View {
		// Only the selected pane is in the hierarchy, so the window shrinks and grows with it.
		pane
			.frame(width: 520)
			.navigationTitle(tab.label)
			.toolbar {
				ToolbarItem(placement: .principal) {
					HStack(spacing: 4) {
						ForEach(Tab.allCases) { item in
							TabButton(tab: item, selected: tab == item) { tab = item }
						}
					}
				}
			}
			.onAppear { NSApp.activate(ignoringOtherApps: true) }
	}

	@ViewBuilder private var pane: some View {
		switch tab {
		case .general: GeneralSettings(streamer: streamer)
		case .stream: StreamSettings()
		case .screen: ScreenSettings(streamer: streamer)
		case .jingles: JingleSettings(streamer: streamer)
		case .internet: InternetSettings()
		case .recording: RecordingSettings()
		case .about: AboutView()
		}
	}
}

/// A classic macOS preferences tab: icon above label, highlighted when selected.
private struct TabButton: View {
	let tab: SettingsView.Tab
	let selected: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			VStack(spacing: 3) {
				Image(systemName: tab.symbol)
					.font(.system(size: 18, weight: .regular))
					.frame(height: 22)
				Text(tab.label)
					.font(.system(size: 11))
			}
			.foregroundStyle(selected ? Color.accentColor : Color.secondary)
			.frame(width: 66)
			.padding(.vertical, 5)
			.background(selected ? Color.primary.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
			.contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
		}
		.buttonStyle(.plain)
		.help(tab.label)
	}
}

private let applyNote = "Changes apply the next time streaming starts; the menu offers a restart while live."

struct GeneralSettings: View {
	var streamer: Streamer
	@AppStorage("sourceMode") private var sourceMode = "device"
	@AppStorage("allApps") private var allApps = false
	@AppStorage("mixInput") private var mixInput = false
	@AppStorage("selectedApps") private var selectedApps = ""
	@State private var apps = AudioApp.running()
	@AppStorage("deviceUID") private var deviceUID = ""
	@AppStorage("streamName") private var streamName = ""
	@AppStorage("port") private var port = 8080
	@AppStorage("autoStart") private var autoStart = false
	@AppStorage("nowPlayingEnabled") private var nowPlayingEnabled = true
	@State private var devices = AudioDevices.inputs()
	@State private var launchAtLogin = SMAppService.mainApp.status == .enabled
	@State private var loginError = ""

	var body: some View {
		Form {
			Section {
				Picker("Capture", selection: $sourceMode) {
					Text("An audio input").tag("device")
					Text("Running applications").tag("apps")
				}
				.pickerStyle(.segmented)
				if sourceMode == "apps" {
					Toggle("All applications", isOn: $allApps)
					if !allApps {
						appList
					}
					Toggle("Also mix in the audio input below", isOn: $mixInput)
				}
				if sourceMode == "device" || mixInput {
					Picker("Input", selection: $deviceUID) {
						ForEach(devices, id: \.uniqueID) { device in
							Text(device.localizedName).tag(device.uniqueID)
						}
					}
				}
				HStack {
					Spacer()
					Button("Refresh") {
						devices = AudioDevices.inputs()
						apps = AudioApp.running()
					}
					.controlSize(.small)
				}
				if streamer.permissionDenied, sourceMode == "device" || mixInput {
					Banner(kind: .error, symbol: "mic.slash.fill", message: "Microphone access is turned off for MicroCast.", actionTitle: "Open Settings", action: SystemSettings.openMicrophonePrivacy)
				}
				if sourceMode == "apps", SystemAudioPermission.status == .denied {
					Banner(kind: .error, symbol: "speaker.slash.fill", message: "System audio recording is turned off for MicroCast.", actionTitle: "Open Settings", action: SystemAudioPermission.openSettings)
				}
			} header: {
				Text("Source")
			} footer: {
				Text(sourceMode == "apps"
					? "Applications are captured through a system audio tap (macOS 14.2+); they keep playing on the Mac. Only apps that have played audio since they launched are listed; macOS asks once for System Audio Recording."
					: "Any Core Audio input works, virtual devices included: Wave Link Stream, BlackHole, Loopback, aggregate devices.")
			}
			Section {
				TextField("Stream name", text: $streamName, prompt: Text("MicroCast"))
				TextField("Port", value: $port, format: .number.grouping(.never))
				Toggle("Show the current track from Music or Spotify", isOn: $nowPlayingEnabled)
					.disabled(sourceMode == "apps")
			} header: {
				Text("Stream")
			} footer: {
				Text(sourceMode == "apps"
					? "The name is shown on the page and sent to players as the stream title. When capturing applications, the track is shown whenever Music or Spotify is among them. \(applyNote)"
					: "The name is shown on the page and sent to players as the stream title. The track is shown while Music or Spotify is playing; turn it off when the input carries something else. \(applyNote)")
			}
			Section("Startup") {
				Toggle("Start streaming when MicroCast launches", isOn: $autoStart)
				Toggle("Launch MicroCast at login", isOn: $launchAtLogin)
					.onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
				if !loginError.isEmpty {
					Text(loginError).font(.caption).foregroundStyle(.orange)
				}
			}
		}
		.formStyle(.grouped)
		.frame(height: generalHeight)
		.onAppear {
			if deviceUID.isEmpty { deviceUID = AudioDevices.preferredInput()?.uniqueID ?? "" }
		}
	}

	private var generalHeight: CGFloat {
		var height: CGFloat = 566
		if sourceMode == "apps" {
			height += 90 + (allApps ? 0 : CGFloat(max(1, apps.count)) * 30)
			if !mixInput { height -= 46 }
		}
		if streamer.permissionDenied { height += 60 }
		return height
	}

	private var selection: Set<String> {
		Set(selectedApps.split(separator: ",").map(String.init))
	}

	@ViewBuilder private var appList: some View {
		if apps.isEmpty {
			Text("No application is playing audio right now.").foregroundStyle(.secondary)
		}
		ForEach(apps) { app in
			Toggle(isOn: Binding(
				get: { selection.contains(app.id) },
				set: { on in
					var set = selection
					if on { set.insert(app.id) } else { set.remove(app.id) }
					selectedApps = set.sorted().joined(separator: ",")
				}
			)) {
				HStack(spacing: 6) {
					if let bundleID = app.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
						Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
					}
					Text(app.name)
					if app.isPlaying {
						Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(.green).help("Playing now")
					}
				}
			}
		}
	}

	private func setLaunchAtLogin(_ enabled: Bool) {
		do {
			if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
			loginError = ""
		} catch {
			loginError = error.localizedDescription
			launchAtLogin = SMAppService.mainApp.status == .enabled
		}
	}
}

struct StreamSettings: View {
	@AppStorage("partDuration") private var partDuration = 0.334
	@AppStorage("segmentDuration") private var segmentDuration = 2.0
	@AppStorage("bitrates") private var bitratesText = ""
	@AppStorage("enableHLS") private var hlsEnabled = true
	@AppStorage("enableAAC") private var aacEnabled = true
	@AppStorage("enableMP3") private var mp3Enabled = true
	@AppStorage("enableFLAC") private var flacEnabled = true
	@AppStorage("enablePCM") private var pcmEnabled = true

	var body: some View {
		Form {
			Section {
				Picker("Part duration", selection: $partDuration) {
					Text("200 ms").tag(0.2)
					Text("250 ms").tag(0.25)
					Text("334 ms").tag(0.334)
					Text("500 ms").tag(0.5)
					Text("1 s").tag(1.0)
				}
				Picker("Segment duration", selection: $segmentDuration) {
					Text("1 s").tag(1.0)
					Text("2 s").tag(2.0)
					Text("4 s").tag(4.0)
				}
				LabeledContent("Expected latency", value: String(format: "≈ %.1f s in hls.js and Safari", partDuration * 3 + 0.5))
			} header: {
				Text("Low-Latency HLS")
			} footer: {
				Text("Shorter parts lower the latency and multiply requests; 334 ms is a good default on Wi-Fi, 500 ms or more through a tunnel. \(applyNote)")
			}
			Section {
				Toggle("Low-Latency HLS", isOn: $hlsEnabled)
				Toggle("AAC, direct stream", isOn: $aacEnabled)
				Toggle("MP3, direct stream", isOn: $mp3Enabled)
				Toggle("FLAC, direct lossless stream", isOn: $flacEnabled)
				Toggle("Raw PCM, the page's ultra-low-latency mode", isOn: $pcmEnabled)
			} header: {
				Text("Formats")
			} footer: {
				Text("Each format costs a little CPU; turn off what nobody listens to. MP3 also needs lame. \(applyNote)")
			}
			Section {
				TextField("Bitrates", text: $bitratesText, prompt: Text(Settings.defaultBitrates.map(String.init).joined(separator: ", ")))
				LabeledContent("In use", value: Settings.parseBitrates(bitratesText).map { "\($0)" }.joined(separator: ", ") + " kbps")
				if !bitratesText.isEmpty {
					HStack {
						Spacer()
						Button("Reset to defaults") { bitratesText = "" }
							.controlSize(.small)
					}
				}
			} header: {
				Text("Bitrates")
			} footer: {
				Text("One rendition per value for HLS, AAC and MP3. 64 to 320 kbps, up to eight values, separated by commas or spaces; other values are adjusted.")
			}
		}
		.formStyle(.grouped)
		.frame(height: bitratesText.isEmpty ? 680 : 710)
	}
}

struct InternetSettings: View {
	@AppStorage("tunnelProvider") private var tunnelProvider = Tunnel.Provider.off.rawValue
	@AppStorage("cloudflareToken") private var cloudflareToken = ""
	@AppStorage("cloudflareHostname") private var cloudflareHostname = ""
	@AppStorage("customTunnelCommand") private var customTunnelCommand = ""
	@AppStorage("password") private var password = ""
	@AppStorage("keepOnline") private var keepOnline = true
	@AppStorage("duckSubdomain") private var duckSubdomain = ""
	@AppStorage("duckToken") private var duckToken = ""
	@AppStorage("duckHostname") private var duckHostname = ""
	@AppStorage("duckPublicPort") private var duckPublicPort = 443
	@AppStorage("httpsEnabled") private var httpsEnabled = true
	@AppStorage("httpsPort") private var httpsPort = 8443
	@AppStorage("acmeEmail") private var acmeEmail = ""
	@AppStorage("ownHostname") private var ownHostname = ""

	private var provider: Tunnel.Provider { Tunnel.Provider(rawValue: tunnelProvider) ?? .off }

	var body: some View {
		Form {
			Section {
				Picker("Tunnel", selection: $tunnelProvider) {
					ForEach(Tunnel.Provider.allCases) { provider in
						Text(provider.label).tag(provider.rawValue)
					}
				}
				switch provider {
				case .cloudflareNamed:
					SecureField("Tunnel token", text: $cloudflareToken, prompt: Text("From Zero Trust → Networks → Tunnels"))
					TextField("Public hostname", text: $cloudflareHostname, prompt: Text("audio.example.com"))
				case .custom:
					TextField("Command", text: $customTunnelCommand, prompt: Text("bore local {port} --to bore.pub"))
				case .duckdns:
					HStack {
						TextField("DuckDNS subdomain", text: $duckSubdomain, prompt: Text("yourname"))
						Text(".duckdns.org").foregroundStyle(.secondary)
					}
					SecureField("DuckDNS token", text: $duckToken)
					TextField("Your own hostname", text: $duckHostname, prompt: Text("optional, e.g. cast.example.com"))
					portForwardingFields
				case .ownHost:
					TextField("Hostname", text: $ownHostname, prompt: Text("cast.example.com"))
					portForwardingFields
				default:
					EmptyView()
				}
			} header: {
				Text("Expose on the internet")
			} footer: {
				Text(hint)
			}
			Section {
				SecureField("Password", text: $password, prompt: Text("None"))
			} header: {
				Text("Access")
			} footer: {
				Text("When set, every address asks for it (any user name). Browsers remember it; VLC and mpv accept https://x:password@host/… \(applyNote)")
			}
			Section {
				Toggle("Stay online while off air", isOn: $keepOnline)
			} header: {
				Text("Between streams")
			} footer: {
				Text("Keeps the address, tunnel and certificate up when you stop; listeners see an off-air page that starts playing by itself when you go live. Off, everything closes with the stream.")
			}
		}
		.formStyle(.grouped)
		.frame(height: 420 + CGFloat(extraRows) * 46)
	}

	private var extraRows: Int {
		switch provider {
		case .cloudflareNamed: 2
		case .custom: 1
		case .duckdns: httpsEnabled ? 8 : 5
		case .ownHost: httpsEnabled ? 6 : 3
		default: 0
		}
	}

	@ViewBuilder private var portForwardingFields: some View {
		TextField("Port forwarded on the router", value: $duckPublicPort, format: .number.grouping(.never))
		Toggle("HTTPS with a Let's Encrypt certificate", isOn: $httpsEnabled)
		if httpsEnabled {
			TextField("Local HTTPS port", value: $httpsPort, format: .number.grouping(.never))
			TextField("Email for certificate notices", text: $acmeEmail, prompt: Text("optional"))
		}
	}

	private var hint: String {
		switch provider {
		case .off: "Streams stay on the local network."
		case .cloudflare: "No account needed. Cloudflare gives a random trycloudflare.com address, new on every start, shown in the menu once the tunnel is connected."
		case .cloudflareNamed: "A stable address on your own domain. In the Cloudflare dashboard, point the tunnel's public hostname at http://localhost:<port>."
		case .ngrok: "Requires an ngrok account: run ngrok config add-authtoken once."
		case .tailscale: "Requires Tailscale with Funnel enabled on your tailnet."
		case .custom: "Any command that prints an https:// address; {port} is replaced by the local port."
		case .ownHost: httpsEnabled
			? "For a name your router or DNS provider already keeps pointed at you (DynDNS). Forward the router port above to the local HTTPS port, and port 80 to the local HTTP port: Let's Encrypt checks the certificate over plain HTTP at issuance and at each renewal."
			: "For a name your router or DNS provider already keeps pointed at you (DynDNS). Forward the router port above to the local HTTP port; listeners get plain http://."
		case .duckdns: httpsEnabled
			? "Free, fixed name from duckdns.org, kept pointed at this Mac. Forward the router port above to the local HTTPS port; the certificate is obtained and renewed through DuckDNS's DNS challenge, no port 80 needed. For your own hostname, add a CNAME to \(duckSubdomain.isEmpty ? "yourname" : duckSubdomain).duckdns.org and a CNAME from _acme-challenge.<host> to _acme-challenge.\(duckSubdomain.isEmpty ? "yourname" : duckSubdomain).duckdns.org."
			: "Free, fixed name from duckdns.org, kept pointed at this Mac. Forward the router port above to the local HTTP port; listeners get plain http://."
		}
	}
}

struct ScreenSettings: View {
	var streamer: Streamer
	@AppStorage("screenEnabled") private var enabled = false
	@AppStorage("screenDisplayID") private var displayID = 0
	@AppStorage("screenFPS") private var fps = 12
	@AppStorage("screenMaxWidth") private var maxWidth = 1280
	@AppStorage("screenQuality") private var quality = 0.7
	@AppStorage("screenX") private var x = 0
	@AppStorage("screenY") private var y = 0
	@AppStorage("screenWidth") private var width = 0
	@AppStorage("screenHeight") private var height = 0
	@State private var displays: [ScreenDisplay] = []
	@State private var picker = ScreenRegionPicker()

	private var wholeDisplay: Bool { width <= 0 || height <= 0 }

	var body: some View {
		Form {
			Section {
				Toggle("Stream a screen region to the page", isOn: $enabled)
				Picker("Display", selection: $displayID) {
					ForEach(displays) { display in
						Text("\(display.name) — \(display.width)×\(display.height)").tag(Int(display.id))
					}
				}
				LabeledContent("Region") {
					HStack {
						Text(wholeDisplay ? "Whole display" : "\(width)×\(height) at (\(x), \(y))")
							.foregroundStyle(.secondary)
						Spacer()
						Button("Select…") { selectRegion() }
							.controlSize(.small)
						Button("Whole display") { x = 0; y = 0; width = 0; height = 0 }
							.controlSize(.small)
							.disabled(wholeDisplay)
					}
				}
				if streamer.permissionScreenDenied {
					Banner(kind: .error, symbol: "rectangle.slash", message: "Screen Recording is turned off for MicroCast.", actionTitle: "Open Settings", action: ScreenPermission.openSettings)
				}
			} header: {
				Text("Source")
			} footer: {
				Text("Captures a display or a region of it with ScreenCaptureKit. macOS asks once for Screen Recording. \(applyNote)")
			}
			Section {
				Picker("Frame rate", selection: $fps) {
					ForEach([5, 10, 12, 15, 20, 30], id: \.self) { Text("\($0) fps").tag($0) }
				}
				Picker("Max width", selection: $maxWidth) {
					ForEach([640, 960, 1280, 1600, 1920], id: \.self) { Text("\($0) px").tag($0) }
				}
				LabeledContent("Quality") {
					HStack {
						Slider(value: $quality, in: 0.3 ... 0.95, step: 0.05)
						Text("\(Int((quality * 100).rounded())) %").monospacedDigit().frame(width: 52, alignment: .trailing)
					}
				}
			} header: {
				Text("Quality")
			} footer: {
				Text("The screen is sent as MJPEG (a stream of JPEG frames) shown in the page; higher rate, width and quality mean more bandwidth. It carries no audio and is not synced to the stream. \(applyNote)")
			}
		}
		.formStyle(.grouped)
		.frame(height: 560)
		.task {
			displays = await ScreenCapture.displays()
			if displayID == 0, let first = displays.first { displayID = Int(first.id) }
		}
	}

	private func selectRegion() {
		guard ScreenPermission.request() else { ScreenPermission.openSettings(); return }
		let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == CGDirectDisplayID(displayID) } ?? NSScreen.main
		guard let screen else { return }
		NSApp.hide(nil)
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
			picker.present(on: screen) { region in
				NSApp.unhide(nil)
				NSApp.activate(ignoringOtherApps: true)
				guard let region else { return }
				x = region.x; y = region.y; width = region.width; height = region.height
			}
		}
	}
}

struct JingleSettings: View {
	var streamer: Streamer
	@AppStorage("jinglesEnabled") private var jinglesEnabled = false
	@AppStorage("jingleFolder") private var jingleFolder = ""
	@AppStorage("jingleDuckDecibels") private var duck = -12.0
	@AppStorage("jingleVolume") private var volume = 1.0
	@AppStorage("jingleLeadSeconds") private var lead = 2.0
	@State private var files: [URL] = []

	var body: some View {
		Form {
			Section {
				Toggle("Play a jingle when the track changes in Music or Spotify", isOn: $jinglesEnabled)
				LabeledContent("Folder") {
					HStack {
						Text((Settings.jingleFolder.path as NSString).abbreviatingWithTildeInPath)
							.lineLimit(1)
							.truncationMode(.middle)
							.foregroundStyle(.secondary)
						Button("Choose…", action: chooseFolder)
							.controlSize(.small)
						Button {
							try? FileManager.default.createDirectory(at: Settings.jingleFolder, withIntermediateDirectories: true)
							NSWorkspace.shared.open(Settings.jingleFolder)
						} label: {
							Image(systemName: "folder")
						}
						.controlSize(.small)
						.help("Open the folder")
					}
				}
				LabeledContent("Files") {
					if files.isEmpty {
						Text("None yet").foregroundStyle(.secondary)
					} else {
						Text(files.map(\.lastPathComponent).joined(separator: ", "))
							.lineLimit(2)
							.truncationMode(.tail)
							.foregroundStyle(.secondary)
					}
				}
				HStack {
					Spacer()
					Button("Refresh") { files = JingleBank(folder: Settings.jingleFolder).files }
						.controlSize(.small)
					Button("Play one now") { streamer.playJingle() }
						.controlSize(.small)
						.disabled(!streamer.isRunning || files.isEmpty)
				}
			} header: {
				Text("Jingles")
			} footer: {
				Text("Drop MP3, AAC, WAV, AIFF or FLAC files in the folder. One is picked at random at each track change, never the same twice in a row. Works with the Now Playing detection, so only when Music or Spotify is what you stream.")
			}
			Section {
				LabeledContent("Start") {
					HStack {
						Slider(value: $lead, in: 0 ... 15, step: 0.5)
						Text(lead == 0 ? "at the change" : String(format: "%.1f s before", lead)).monospacedDigit().frame(width: 96, alignment: .trailing)
					}
				}
				LabeledContent("Music under the jingle") {
					HStack {
						Slider(value: $duck, in: -30 ... 0, step: 1)
						Text(duck >= 0 ? "no duck" : "\(Int(duck)) dB").monospacedDigit().frame(width: 60, alignment: .trailing)
					}
				}
				LabeledContent("Jingle volume") {
					HStack {
						Slider(value: $volume, in: 0.3 ... 1.5, step: 0.05)
						Text("\(Int((volume * 100).rounded())) %").monospacedDigit().frame(width: 52, alignment: .trailing)
					}
				}
			} header: {
				Text("Mix")
			} footer: {
				Text("With a lead time, the jingle starts that many seconds before the end of the track as the player reports it. If Music crossfades songs (Music → Settings → Playback), the next song is already audible during the crossfade: add its duration to the lead. A track skipped before that point gets its jingle at the change. The music fades to the chosen level in half a second and comes back over a second.")
			}
		}
		.formStyle(.grouped)
		.frame(height: 540)
		.onAppear { files = JingleBank(folder: Settings.jingleFolder).files }
	}

	private func chooseFolder() {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.canCreateDirectories = true
		panel.directoryURL = Settings.jingleFolder
		panel.prompt = "Use this folder"
		if panel.runModal() == .OK, let url = panel.url {
			jingleFolder = url.path
			files = JingleBank(folder: url).files
		}
	}
}

struct RecordingSettings: View {
	@AppStorage("recordFormat") private var recordFormat = "off"
	@AppStorage("recordFolder") private var recordFolder = ""

	var body: some View {
		Form {
			Section {
				Picker("Record", selection: $recordFormat) {
					Text("Off").tag("off")
					Text("FLAC, lossless").tag("flac")
					Text("AAC 320 kbps").tag("aac")
					Text("MP3 320 kbps").tag("mp3")
				}
				LabeledContent("Folder") {
					HStack {
						Text(folderLabel)
							.lineLimit(1)
							.truncationMode(.middle)
							.foregroundStyle(.secondary)
						Button("Choose…", action: chooseFolder)
							.controlSize(.small)
						Button {
							NSWorkspace.shared.open(Settings.recordFolder)
						} label: {
							Image(systemName: "folder")
						}
						.controlSize(.small)
						.help("Open the folder")
					}
				}
			} header: {
				Text("Keep a copy of every session")
			} footer: {
				Text("A new file starts with each stream, named after the stream and the date. \(applyNote)")
			}
		}
		.formStyle(.grouped)
		.frame(height: 250)
	}

	private var folderLabel: String {
		(Settings.recordFolder.path as NSString).abbreviatingWithTildeInPath
	}

	private func chooseFolder() {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.canCreateDirectories = true
		panel.directoryURL = Settings.recordFolder
		panel.prompt = "Use this folder"
		if panel.runModal() == .OK, let url = panel.url {
			recordFolder = url.path
		}
	}
}

struct AboutView: View {
	private var version: String {
		let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
		let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
		return build.isEmpty ? short : "\(short) (\(build))"
	}

	var body: some View {
		VStack(spacing: 10) {
			Image(nsImage: NSApp.applicationIconImage)
				.resizable()
				.frame(width: 96, height: 96)
			Text("MicroCast").font(.title2.weight(.semibold))
			Text("Version \(version)").font(.callout).foregroundStyle(.secondary)
			Text("Turn any audio input into a live stream: low-latency HLS, AAC, MP3, FLAC and raw PCM, on your network or through a tunnel.")
				.multilineTextAlignment(.center)
				.font(.callout)
				.foregroundStyle(.secondary)
				.frame(maxWidth: 360)
				.padding(.top, 4)
			HStack(spacing: 16) {
				Link("GitHub", destination: URL(string: "https://github.com/eko/microcast")!)
				Link("Documentation", destination: URL(string: "https://github.com/eko/microcast/tree/main/docs")!)
				Link("MIT License", destination: URL(string: "https://github.com/eko/microcast/blob/main/LICENSE")!)
			}
			.font(.callout)
			.padding(.top, 6)
			Text("© Vincent Composieux")
				.font(.caption)
				.foregroundStyle(.tertiary)
				.padding(.top, 10)
		}
		.padding(28)
		.frame(maxWidth: .infinity)
	}
}
