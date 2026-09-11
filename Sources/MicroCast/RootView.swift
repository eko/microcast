import SwiftUI

/// The window's shell.
///
/// One window holds both screens: the dashboard slides aside for settings and comes back, rather
/// than settings opening a second window the way a menu bar utility usually does. The title bar is
/// drawn here because the window's own is hidden, which is what lets the header carry the stream's
/// state instead of a filename.
struct RootView: View {
	enum Route: Equatable { case dashboard, settings }

	var streamer: Streamer
	@Environment(\.colorScheme) private var scheme
	@AppStorage("streamName") private var streamName = ""
	@State private var route: Route = .dashboard
	@State private var settingsTab: SettingsView.Tab = .general

	var body: some View {
		ZStack {
			AmbientBackground(live: streamer.isRunning)

			VStack(spacing: 0) {
				titleBar
				Divider().opacity(0.45)
				content
			}
		}
		// A hairline along the top edge, the way a physical panel catches the light. Without the
		// traffic lights there is nothing else up there to give the window an edge. A lit line
		// only reads against a dark ground, so on white it becomes a shadow instead. A plain fill
		// rather than a blend mode, which would have the compositor draw the group off screen.
		.overlay(alignment: .top) {
			Rectangle()
				.fill(scheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.07))
				.frame(height: 1)
				.allowsHitTesting(false)
		}
		.ignoresSafeArea()
		.frame(minWidth: 480, idealWidth: 520, minHeight: 560, idealHeight: 680)
		.onChange(of: streamer.isRunning, initial: true) { _, running in
			AppDelegate.shared?.setRunning(running)
		}
		.onAppear {
			AppDelegate.shared?.onShortcut = { shortcut in
				switch shortcut {
				case .settings: route = .settings
				case .back: route = .dashboard
				case .toggleStream:
					guard route == .dashboard, !streamer.isStarting, !streamer.permissionDenied else { return }
					if streamer.isRunning { streamer.stop() } else { Task { await streamer.start() } }
				}
			}
		}
	}

	@ViewBuilder private var content: some View {
		ZStack {
			switch route {
			case .dashboard:
				DashboardView(streamer: streamer) { tab in
					settingsTab = tab
					route = .settings
				}
					.transition(.asymmetric(
						insertion: .move(edge: .leading).combined(with: .opacity),
						removal: .move(edge: .leading).combined(with: .opacity)))
			case .settings:
				SettingsView(streamer: streamer, tab: settingsTab)
					.id(settingsTab)
					.transition(.asymmetric(
						insertion: .move(edge: .trailing).combined(with: .opacity),
						removal: .move(edge: .trailing).combined(with: .opacity)))
			}
		}
		.animation(.spring(response: 0.36, dampingFraction: 0.88), value: isSettings)
	}

	private var isSettings: Bool { if case .settings = route { return true }; return false }

	// MARK: Title bar

	private var titleBar: some View {
		HStack(spacing: 10) {
			if isSettings {
				Button {
					route = .dashboard
				} label: {
					Image(systemName: "chevron.left")
				}
				.buttonStyle(ChromeButtonStyle())
				.help("Back")
				.keyboardShortcut(.cancelAction)
				Text("Settings")
					.font(.system(size: 14, weight: .semibold, design: .rounded))
			} else {
				Image(nsImage: NSApp.applicationIconImage)
					.resizable()
					.frame(width: 22, height: 22)
				Text(streamName.isEmpty ? "MicroCast" : streamName)
					.font(.system(size: 14, weight: .semibold, design: .rounded))
					.lineLimit(1)
				if streamer.isRunning { LivePill() }
			}

			Spacer(minLength: 8)

			if !isSettings {
				if streamer.isRunning, streamer.jingleCount > 0 {
					Button { streamer.playJingle() } label: {
						Image(systemName: "music.quarternote.3")
					}
					.buttonStyle(ChromeButtonStyle())
					.help("Play a jingle now")
				}
				Button {
					route = .settings
				} label: {
					Image(systemName: "gearshape")
				}
				.buttonStyle(ChromeButtonStyle())
				.help("Settings")
				.keyboardShortcut(",")
			}
		}
		// Nothing to clear on the left any more: the traffic lights are hidden.
		.padding(.horizontal, 16)
		.frame(height: 46)
		.animation(.spring(response: 0.3, dampingFraction: 0.9), value: streamer.isRunning)
	}
}
