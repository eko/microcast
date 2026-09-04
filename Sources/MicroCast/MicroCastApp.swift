import SwiftUI

@main
struct MicroCastApp: App {
	@State private var streamer = Streamer()

	var body: some Scene {
		MenuBarExtra {
			MenuView(streamer: streamer)
		} label: {
			Image(systemName: streamer.isRunning ? "dot.radiowaves.left.and.right" : "radio")
		}
		.menuBarExtraStyle(.window)

		SwiftUI.Settings {
			SettingsView(streamer: streamer)
		}
		.windowResizability(.contentSize)
	}
}
