import AVFoundation
import Charts
import SwiftUI

/// The menu bar popover: status, level, one button, and the addresses to share.
struct MenuView: View {
	var streamer: Streamer
	@AppStorage("streamName") private var streamName = ""

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
				.padding(.horizontal, 16)
				.padding(.top, 14)
				.padding(.bottom, 12)
			LevelMeter(left: streamer.levelLeft, right: streamer.levelRight, peakLeft: streamer.peakLeft, peakRight: streamer.peakRight)
				.padding(.horizontal, 16)
				.padding(.bottom, 12)
				.opacity(streamer.isRunning ? 1 : 0.35)
			nowPlayingRow
			primaryButton
				.padding(.horizontal, 16)
				.padding(.bottom, 14)
			banners
			if streamer.isOnline {
				Divider()
				listen
					.padding(16)
			}
			if streamer.isRunning {
				Divider()
				listenersChart
					.padding(16)
			}
			if let recording = streamer.recordingURL {
				Divider()
				recordingRow(recording)
					.padding(.horizontal, 16)
					.padding(.vertical, 12)
			}
			Divider()
			footer
				.padding(.horizontal, 12)
				.padding(.vertical, 8)
		}
		.frame(width: 340)
	}

	// MARK: Header

	private var header: some View {
		HStack(spacing: 10) {
			Image(nsImage: NSApp.applicationIconImage)
				.resizable()
				.frame(width: 36, height: 36)
			VStack(alignment: .leading, spacing: 2) {
				Text(streamName.isEmpty ? "MicroCast" : streamName)
					.font(.headline)
					.lineLimit(1)
				statusLine
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
			Spacer()
			if streamer.isRunning, streamer.jingleCount > 0 {
				Button {
					streamer.playJingle()
				} label: {
					Image(systemName: "music.quarternote.3")
				}
				.buttonStyle(.borderless)
				.help("Play a jingle now")
				.padding(.trailing, 6)
			}
			if streamer.isRunning {
				Text("LIVE")
					.font(.system(size: 10, weight: .bold))
					.kerning(0.5)
					.foregroundStyle(.white)
					.padding(.horizontal, 7)
					.padding(.vertical, 3)
					.background(Color.red, in: Capsule())
			}
		}
	}

	@ViewBuilder private var statusLine: some View {
		if streamer.isStarting {
			Text("Starting…")
		} else if streamer.isRunning, let startedAt = streamer.startedAt {
			HStack(spacing: 4) {
				Text(streamer.deviceName)
				Text("·")
				Text(startedAt, style: .timer).monospacedDigit()
				Text("·")
				Text(streamer.listeners == 1 ? "1 listener" : "\(streamer.listeners) listeners")
			}
		} else if streamer.isOnline {
			Text("Off air · online" + (streamer.deviceName.isEmpty ? "" : " · \(streamer.deviceName)"))
		} else {
			Text(streamer.deviceName.isEmpty ? "Not streaming" : "Ready · \(streamer.deviceName)")
		}
	}

	@ViewBuilder private var nowPlayingRow: some View {
		if let track = streamer.nowPlaying {
			HStack(spacing: 8) {
				Image(systemName: "music.note")
					.font(.caption)
					.foregroundStyle(.secondary)
				VStack(alignment: .leading, spacing: 1) {
					Text(track.title).font(.callout.weight(.medium)).lineLimit(1)
					Text("\(track.artist)\(track.album.isEmpty ? "" : " · \(track.album)") · \(track.source)")
						.font(.caption)
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
			}
			.padding(.horizontal, 16)
			.padding(.bottom, 12)
		}
	}

	private var primaryButton: some View {
		Button {
			if streamer.isRunning {
				streamer.stop()
			} else {
				Task { await streamer.start() }
			}
		} label: {
			Label(streamer.isRunning ? "Stop streaming" : "Start streaming", systemImage: streamer.isRunning ? "stop.fill" : "play.fill")
		}
		.buttonStyle(PrimaryButtonStyle(color: streamer.isRunning ? .red : .accentColor))
		.keyboardShortcut(.defaultAction)
		.disabled(streamer.isStarting || streamer.permissionDenied)
		.opacity(streamer.isStarting || streamer.permissionDenied ? 0.5 : 1)
	}

	@ViewBuilder private var banners: some View {
		let items = VStack(spacing: 8) {
			if let failure = streamer.failure, !streamer.isRunning {
				Banner(kind: .error, symbol: "exclamationmark.octagon.fill", message: failure)
			}
			if streamer.permissionDenied {
				Banner(kind: .error, symbol: "mic.slash.fill", message: "Microphone access is turned off for MicroCast, which blocks every audio input.", actionTitle: "Open Settings", action: SystemSettings.openMicrophonePrivacy)
			}
			if streamer.isRunning, streamer.settingsChanged {
				Banner(kind: .info, symbol: "arrow.triangle.2.circlepath", message: "Settings changed since the stream started.", actionTitle: "Restart") {
					Task { await streamer.restart() }
				}
			}
			if streamer.lame == nil {
				Banner(kind: .warning, symbol: "exclamationmark.triangle.fill", message: "MP3 is unavailable: install lame with Homebrew (brew install lame).")
			}
		}
		if streamer.failure != nil || streamer.permissionDenied || (streamer.isRunning && streamer.settingsChanged) || streamer.lame == nil {
			items
				.padding(.horizontal, 16)
				.padding(.bottom, 14)
		}
	}

	// MARK: Listen

	private var listen: some View {
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
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			VStack(alignment: .leading, spacing: 5) {
				if let url = streamer.tunnelURL {
					addressRow(url, symbol: "globe", tint: .green)
				}
				ForEach(shareableURLs, id: \.self) { url in
					addressRow(url, symbol: url.host == "localhost" ? "desktopcomputer" : "wifi", tint: .secondary)
				}
			}
			if let primary = primaryURL, let qr = QRCode.image(for: primary) {
				HStack(spacing: 12) {
					Image(nsImage: qr)
						.interpolation(.none)
						.resizable()
						.frame(width: 64, height: 64)
						.padding(4)
						.background(Color.white, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
					VStack(alignment: .leading, spacing: 2) {
						Text("Scan to listen on a phone")
							.font(.callout.weight(.medium))
						Text(Self.display(primary))
							.font(.caption)
							.foregroundStyle(.secondary)
							.lineLimit(1)
							.truncationMode(.middle)
					}
				}
				.padding(.top, 2)
			}
		}
	}

	/// The local addresses worth sharing: the Bonjour name and the LAN IPs; localhost only when nothing else exists.
	private var shareableURLs: [URL] {
		let others = streamer.pageURLs.filter { $0.host != "localhost" }
		return others.isEmpty ? streamer.pageURLs : others
	}

	private var primaryURL: URL? {
		streamer.tunnelURL ?? streamer.pageURLs.first { $0.host?.hasSuffix(".local") == true } ?? shareableURLs.first
	}

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
				Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
			}
			.buttonStyle(.borderless)
			.help("Share, or AirDrop to your phone")
		}
	}

	// MARK: Listeners

	private var listenersChart: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(alignment: .firstTextBaseline) {
				SectionTitle(text: "Listeners")
				Spacer()
				Text("\(streamer.listeners) now · peak \(streamer.peakListeners)")
					.font(.caption)
					.foregroundStyle(.secondary)
					.monospacedDigit()
			}
			Chart(streamer.listenerSamples) { sample in
				AreaMark(x: .value("Time", sample.time), y: .value("Listeners", sample.count))
					.interpolationMethod(.monotone)
					.foregroundStyle(.linearGradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.02)], startPoint: .top, endPoint: .bottom))
				LineMark(x: .value("Time", sample.time), y: .value("Listeners", sample.count))
					.interpolationMethod(.monotone)
					.foregroundStyle(Color.accentColor)
					.lineStyle(StrokeStyle(lineWidth: 1.5))
			}
			.chartXAxis(.hidden)
			.chartYAxis {
				AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
					AxisGridLine().foregroundStyle(.quaternary)
					AxisValueLabel().font(.system(size: 9)).foregroundStyle(.tertiary)
				}
			}
			.chartYScale(domain: 0...max(2, streamer.peakListeners))
			.frame(height: 56)
			Text(chartCaption)
				.font(.system(size: 10))
				.foregroundStyle(.tertiary)
		}
	}

	private var chartCaption: String {
		guard let first = streamer.listenerSamples.first else { return "Sampled every 5 s" }
		let minutes = max(1, Int(Date().timeIntervalSince(first.time) / 60))
		return minutes < 30 ? "Last \(minutes) min" : "Last 30 min"
	}

	// MARK: Recording

	private func recordingRow(_ url: URL) -> some View {
		HStack(spacing: 8) {
			Image(systemName: "record.circle.fill")
				.foregroundStyle(.red)
				.symbolEffect(.pulse, options: .repeating)
			VStack(alignment: .leading, spacing: 1) {
				Text("Recording")
					.font(.callout.weight(.medium))
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
				.foregroundStyle(.secondary)
			}
			Spacer()
			Button {
				NSWorkspace.shared.activateFileViewerSelecting([url])
			} label: {
				Image(systemName: "folder").foregroundStyle(.secondary)
			}
			.buttonStyle(.borderless)
			.help("Show in Finder")
		}
	}

	// MARK: Footer

	private var footer: some View {
		HStack {
			SettingsLink {
				Label("Settings…", systemImage: "gearshape")
			}
			.simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
			.keyboardShortcut(",")
			Spacer()
			if streamer.isOnline, !streamer.isRunning {
				Button("Go offline") { streamer.goOffline() }
					.help("Stop serving the off-air page and close the tunnel")
			} else if !streamer.isOnline, !streamer.isRunning {
				Button("Go online") { Task { await streamer.goOnline() } }
					.help("Serve the address with the off-air page without streaming")
			}
			Spacer()
			Button("Quit") { NSApplication.shared.terminate(nil) }
				.keyboardShortcut("q")
		}
		.buttonStyle(.borderless)
		.foregroundStyle(.secondary)
		.font(.callout)
	}
}
