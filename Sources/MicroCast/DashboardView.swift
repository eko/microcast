import AVFoundation
import Charts
import SwiftUI

/// The main screen: what the stream is doing, the one button that changes it, and the addresses
/// to hand out. Everything sits in cards so the eye can skip to the part it wants.
struct DashboardView: View {
	var streamer: Streamer
	var openSettings: (SettingsView.Tab) -> Void
	@State private var jingleFiles = 0
	/// Swaps the real addresses for example ones while shooting documentation, so a public
	/// README never ships someone's domain, host name and LAN address.
	@AppStorage("demoAddresses") private var demoAddresses = false

	var body: some View {
		// The window is resizable and its size is remembered, so the content has to sit well in a
		// tall one too. Given at least the height of the viewport, a short dashboard centres
		// itself instead of clinging to the top over a dead half-window; a long one scrolls.
		GeometryReader { proxy in
			ScrollView {
				VStack(spacing: 14) {
					banners
					hero
					if !live { preflightCard }
					if streamer.nowPlaying != nil { nowPlayingCard }
					if streamer.isRunning { listenersCard }
					if streamer.isOnline { listenCard }
					if let recording = streamer.recordingURL { RecordingCard(streamer: streamer, url: recording) }
					footer
				}
				.padding(.horizontal, 16)
				.padding(.vertical, 16)
				.frame(minHeight: proxy.size.height)
			}
		}
		.scrollContentBackground(.hidden)
		.onAppear { jingleFiles = JingleBank(folder: Settings.jingleFolder).files.count }
	}

	/// "Live" covers starting too: the meters are meaningful from the moment capture begins.
	private var live: Bool { streamer.isRunning || streamer.isStarting }

	// MARK: Hero

	private var hero: some View {
		Card(padding: 18) {
			VStack(alignment: .leading, spacing: 14) {
				VStack(alignment: .leading, spacing: 4) {
					Text(headline)
						.font(.system(size: 22, weight: .bold, design: .rounded))
						.contentTransition(.numericText())
					statusLine
						.font(.callout)
						.foregroundStyle(.muted)
						.lineLimit(1)
				}

				if live { LiveMeters(streamer: streamer) }

				if streamer.isRunning { Vitals(streamer: streamer) }

				BroadcastButton(
					live: streamer.isRunning,
					starting: streamer.isStarting,
					blocked: streamer.permissionDenied
				) {
					if streamer.isRunning {
						streamer.stop()
					} else {
						Task { await streamer.start() }
					}
				}
				.padding(.top, 4)
			}
		}
		.animation(.spring(response: 0.35, dampingFraction: 0.9), value: streamer.isRunning)
	}

	private var headline: String {
		if streamer.isStarting { return "Starting…" }
		if streamer.isRunning { return "On air" }
		return "Ready to go live"
	}

	@ViewBuilder private var statusLine: some View {
		if streamer.isStarting {
			Text("Bringing the encoders up")
		} else if streamer.isRunning {
			Text(streamer.deviceName.isEmpty ? "Streaming" : streamer.deviceName)
		} else {
			HStack(spacing: 5) {
				Text(streamer.deviceName.isEmpty ? "No input selected" : streamer.deviceName)
				if streamer.isOnline {
					Text("·")
					Text("off-air page online")
				}
				if let last = Settings.lastLive {
					Text("·")
					Text("last on air \(last.formatted(.relative(presentation: .named)))")
				}
			}
		}
	}

	/// What the stream will be once it starts. Off air this is the most useful thing on screen:
	/// it answers "is everything set?" without a trip through four settings tabs.
	private var preflightCard: some View {
		Card {
			VStack(alignment: .leading, spacing: 10) {
				SectionTitle(text: "Before you go live")
				VStack(spacing: 8) {
					PreflightRow(
						symbol: Settings.sourceMode == "apps" ? "square.stack.3d.up" : "mic",
						label: "Source", value: sourceSummary,
						ready: !streamer.deviceName.isEmpty && !streamer.permissionDenied
					) { openSettings(.general) }

					PreflightRow(
						symbol: "waveform", label: "Formats", value: formatSummary,
						ready: !enabledFormats.isEmpty
					) { openSettings(.stream) }

					PreflightRow(
						symbol: addressReady ? "globe" : "wifi",
						label: "Address", value: addressSummary, ready: true
					) { openSettings(.internet) }

					PreflightRow(
						symbol: "music.quarternote.3", label: "Jingles", value: jingleSummary,
						ready: !Settings.jinglesEnabled || jingleFiles > 0
					) { openSettings(.jingles) }
				}
			}
		}
	}

	private var sourceSummary: String {
		if streamer.permissionDenied { return "Microphone access is off" }
		if streamer.deviceName.isEmpty { return "Pick an input or an application" }
		return streamer.deviceName + (Settings.sourceMode == "apps" && Settings.mixInput ? " · with the input mixed in" : "")
	}

	private var enabledFormats: [String] {
		var names: [String] = []
		if Settings.hlsEnabled { names.append("HLS") }
		if Settings.aacEnabled { names.append("AAC") }
		if Settings.mp3Enabled { names.append("MP3") }
		if Settings.flacEnabled { names.append("FLAC") }
		if Settings.pcmEnabled { names.append("PCM") }
		return names
	}

	private var formatSummary: String {
		let names = enabledFormats
		guard !names.isEmpty else { return "Nothing is enabled to stream" }
		let rates = Settings.bitrates.map(String.init).joined(separator: "/")
		return names.joined(separator: " · ") + " · \(rates) kbps"
	}

	/// True when listeners outside the network will have somewhere to connect to.
	private var addressReady: Bool { Settings.tunnelProvider != "off" }

	private var addressSummary: String {
		if demoAddresses { return "cast.example.com" }
		return switch Settings.tunnelProvider {
		case "off": "Local network · port \(Settings.port)"
		case "ownHost": Settings.ownHostname.isEmpty ? "Your own hostname" : Settings.ownHostname
		case "duckdns": Settings.duckHostname.isEmpty ? "DuckDNS" : Settings.duckHostname
		case "cloudflareNamed": Settings.cloudflareHostname.isEmpty ? "Cloudflare tunnel" : Settings.cloudflareHostname
		default: "Tunnel · \(Settings.tunnelProvider)"
		}
	}

	private var jingleSummary: String {
		guard Settings.jinglesEnabled else { return "Off" }
		guard jingleFiles > 0 else { return "Turned on, but the folder is empty" }
		let every = Settings.jingleEveryTracks
		let files = jingleFiles == 1 ? "1 file" : "\(jingleFiles) files"
		return every == 1 ? "\(files) · every track" : "\(files) · every \(every) tracks"
	}


	// MARK: Cards

	@ViewBuilder private var banners: some View {
		let needed = streamer.failure != nil || streamer.permissionDenied
			|| (streamer.isRunning && streamer.settingsChanged) || streamer.lame == nil
		if needed {
			VStack(spacing: 8) {
				if let failure = streamer.failure, !streamer.isRunning {
					Banner(kind: .error, symbol: "exclamationmark.octagon.fill", message: failure)
				}
				if streamer.permissionDenied {
					Banner(kind: .error, symbol: "mic.slash.fill",
					       message: "Microphone access is turned off for MicroCast, which blocks every audio input.",
					       actionTitle: "Open Settings", action: SystemSettings.openMicrophonePrivacy)
				}
				if streamer.isRunning, streamer.settingsChanged {
					Banner(kind: .info, symbol: "arrow.triangle.2.circlepath",
					       message: "Settings changed since the stream started.", actionTitle: "Restart") {
						Task { await streamer.restart() }
					}
				}
				if streamer.lame == nil {
					Banner(kind: .warning, symbol: "exclamationmark.triangle.fill",
					       message: "MP3 is unavailable: install lame with Homebrew (brew install lame).")
				}
			}
		}
	}

	@ViewBuilder private var nowPlayingCard: some View {
		if let track = streamer.nowPlaying {
			Card(padding: 12) {
				HStack(spacing: 12) {
					cover
					VStack(alignment: .leading, spacing: 3) {
						Text(track.title)
							.font(.system(size: 15, weight: .semibold))
							.lineLimit(1)
						Text(track.artist)
							.font(.system(size: 12))
							.foregroundStyle(.muted)
							.lineLimit(1)
						if !track.album.isEmpty {
							Text(track.album)
								.font(.system(size: 11))
								.foregroundStyle(.faint)
								.lineLimit(1)
						}
					}
					Spacer(minLength: 0)
				}
			}
			.animation(.easeInOut(duration: 0.35), value: track.trackID)
		}
	}

	@ViewBuilder private var cover: some View {
		let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
		if let art = streamer.artwork {
			Image(nsImage: art)
				.resizable()
				.scaledToFill()
				.frame(width: 52, height: 52)
				.clipShape(shape)
				.overlay(shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
				.shadow(color: .black.opacity(0.25), radius: 5, y: 2)
		} else {
			Image(systemName: "music.note")
				.font(.system(size: 20))
				.foregroundStyle(Color.accentColor)
				.frame(width: 52, height: 52)
				.background(Color.accentColor.opacity(0.12), in: shape)
		}
	}

	private var listenersCard: some View {
		Card {
			VStack(alignment: .leading, spacing: 10) {
				HStack(alignment: .firstTextBaseline) {
					SectionTitle(text: "Listeners")
					Spacer()
					Text(chartCaption)
						.font(.system(size: 10))
						.foregroundStyle(.faint)
				}
				Chart(streamer.listenerSamples) { sample in
					AreaMark(x: .value("Time", sample.time), y: .value("Listeners", sample.count))
						.interpolationMethod(.monotone)
						.foregroundStyle(.linearGradient(
							colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.02)],
							startPoint: .top, endPoint: .bottom))
					LineMark(x: .value("Time", sample.time), y: .value("Listeners", sample.count))
						.interpolationMethod(.monotone)
						.foregroundStyle(Color.accentColor)
						.lineStyle(StrokeStyle(lineWidth: 2))
				}
				.chartXAxis(.hidden)
				.chartYAxis {
					AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { _ in
						AxisGridLine().foregroundStyle(.quaternary)
						AxisValueLabel().font(.system(size: 9)).foregroundStyle(.faint)
					}
				}
				.chartYScale(domain: 0...max(2, streamer.peakListeners))
				.frame(height: 64)
			}
		}
	}

	private var chartCaption: String {
		guard let first = streamer.listenerSamples.first else { return "Sampled every 5 s" }
		let minutes = max(1, Int(Date().timeIntervalSince(first.time) / 60))
		return minutes < 30 ? "Last \(minutes) min" : "Last 30 min"
	}

	private var listenCard: some View {
		Card {
			VStack(alignment: .leading, spacing: 10) {
				SectionTitle(text: "Listen")
				if !streamer.tunnelStatus.isEmpty {
					HStack(spacing: 8) {
						if streamer.tunnelStatus.hasSuffix("…") {
							ProgressView().controlSize(.small)
						} else {
							Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
						}
						Text(streamer.tunnelStatus)
							.font(.callout)
							.foregroundStyle(.muted)
							.fixedSize(horizontal: false, vertical: true)
					}
				}
				VStack(alignment: .leading, spacing: 5) {
					if let url = streamer.tunnelURL, !demoAddresses {
						addressRow(url, symbol: "globe", tint: .green)
					}
					ForEach(shareableURLs, id: \.self) { url in
						addressRow(url, symbol: url.host == "localhost" ? "desktopcomputer" : "wifi", tint: .muted)
					}
				}
				if let primary = primaryURL, let qr = QRCode.cached(for: primary) {
					HStack(spacing: 12) {
						Image(nsImage: qr)
							.interpolation(.none)
							.resizable()
							.frame(width: 64, height: 64)
							.padding(5)
							.background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
						VStack(alignment: .leading, spacing: 2) {
							Text("Scan to listen on a phone")
								.font(.callout.weight(.medium))
							Text(Self.display(primary))
								.font(.caption)
								.foregroundStyle(.muted)
								.lineLimit(1)
								.truncationMode(.middle)
						}
						Spacer(minLength: 0)
					}
					.padding(.top, 2)
				}
			}
		}
	}


	private var footer: some View {
		HStack {
			if streamer.isOnline, !streamer.isRunning {
				Button("Go offline") { streamer.goOffline() }
					.help("Stop serving the off-air page and close the tunnel")
			} else if !streamer.isOnline, !streamer.isRunning {
				Button("Go online") { Task { await streamer.goOnline() } }
					.help("Serve the address with the off-air page without streaming")
			}
			Spacer()
			Button("Quit MicroCast") { NSApplication.shared.terminate(nil) }
				.keyboardShortcut("q")
		}
		.buttonStyle(.link)
		.font(.callout)
		.foregroundStyle(.muted)
		.padding(.horizontal, 4)
		.padding(.top, 2)
	}

	// MARK: Addresses

	/// The local addresses worth sharing: the Bonjour name and the LAN IPs; localhost only when
	/// nothing else exists.
	private var shareableURLs: [URL] {
		if demoAddresses { return Self.demoURLs }
		let others = streamer.pageURLs.filter { $0.host != "localhost" }
		return others.isEmpty ? streamer.pageURLs : others
	}

	private var primaryURL: URL? {
		if demoAddresses { return Self.demoURLs.first }
		return streamer.tunnelURL
			?? streamer.pageURLs.first { $0.host?.hasSuffix(".local") == true }
			?? shareableURLs.first
	}

	private static let demoURLs = [
		URL(string: "https://cast.example.com/")!,
		URL(string: "http://studio.local:8080/")!,
		URL(string: "http://192.168.1.42:8080/")!,
	]

	private static func display(_ url: URL) -> String {
		var text = url.absoluteString
		for prefix in ["https://", "http://"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
		if text.hasSuffix("/") { text.removeLast() }
		return text
	}

	private func addressRow(_ url: URL, symbol: String, tint: Color) -> some View {
		HStack(spacing: 6) {
			Image(systemName: symbol)
				.font(.caption)
				.foregroundStyle(tint)
				.frame(width: 14)
			Button {
				NSWorkspace.shared.open(url)
			} label: {
				Text(Self.display(url))
					.font(.system(size: 12, design: .monospaced))
					.lineLimit(1)
					.truncationMode(.middle)
			}
			.buttonStyle(.plain)
			.help("Open in the browser")
			Spacer(minLength: 4)
			CopyButton(text: url.absoluteString)
			ShareLink(item: url) {
				Image(systemName: "square.and.arrow.up").foregroundStyle(.muted)
			}
			.buttonStyle(.borderless)
			.help("Share, or AirDrop to your phone")
		}
	}
}

/// The needles, split out on purpose.
///
/// The meters take their readings straight from the streamer and move in Core Animation between
/// them, so nothing here is re-evaluated twenty times a second; this view only follows whether
/// the stream is out, for the colour. `meterStyle` = "wave" swaps the VU pair for the waveform.
private struct LiveMeters: View {
	var streamer: Streamer

	var body: some View {
		if Settings.meterStyle == "wave" {
			SignalTrace(streamer: streamer, live: streamer.isRunning)
				.frame(height: 78)
		} else {
			VUMeters(streamer: streamer, live: streamer.isRunning)
				.frame(height: 112)
		}
	}
}

/// Counters, likewise kept off the dashboard's own dependency list.
private struct Vitals: View {
	var streamer: Streamer

	var body: some View {
		HStack(spacing: 0) {
			if let startedAt = streamer.startedAt {
				StatTile(value: "", label: "Uptime", symbol: "clock")
					.overlay(alignment: .bottomLeading) {
						Text(startedAt, style: .timer)
							.font(.system(size: 17, weight: .semibold, design: .rounded))
							.monospacedDigit()
					}
			}
			StatTile(value: "\(streamer.listeners)", label: "Listeners", symbol: "person.2")
				.contentTransition(.numericText())
			StatTile(value: "\(streamer.peakListeners)", label: "Peak", symbol: "chart.line.uptrend.xyaxis")
		}
	}
}

private struct RecordingCard: View {
	var streamer: Streamer
	var url: URL

	var body: some View {
		Card {
			HStack(spacing: 10) {
				Image(systemName: "record.circle.fill")
					.font(.system(size: 18))
					.foregroundStyle(.red)
					.symbolEffect(.pulse, options: .repeating)
				VStack(alignment: .leading, spacing: 2) {
					Text("Recording").font(.system(size: 14, weight: .semibold))
					HStack(spacing: 4) {
						if let startedAt = streamer.startedAt {
							Text(startedAt, style: .timer).monospacedDigit()
							Text("·")
						}
						Text(ByteCountFormatter.string(fromByteCount: streamer.recordingBytes, countStyle: .file))
						Text("·")
						Text(url.pathExtension.uppercased())
					}
					.font(.caption)
					.foregroundStyle(.muted)
				}
				Spacer()
				Button {
					NSWorkspace.shared.activateFileViewerSelecting([url])
				} label: {
					Image(systemName: "folder")
				}
				.buttonStyle(ChromeButtonStyle())
				.help("Show in Finder")
			}
		}
	}
}
