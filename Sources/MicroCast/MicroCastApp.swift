import SwiftUI

@main
struct MicroCastApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

	var body: some Scene {
		// The real window is built by the delegate, which needs to own its lifetime in order to
		// hide and restore it. This scene exists only because an App must declare one; it is
		// never shown.
		SwiftUI.Settings { EmptyView() }
			// That placeholder scene would otherwise put a "Settings…" item in the app menu, opening
			// an empty window and stealing ⌘, from the button that actually goes to settings.
			.commands {
				CommandGroup(replacing: .appSettings) {}
				CommandGroup(replacing: .newItem) {}
			}
	}
}
