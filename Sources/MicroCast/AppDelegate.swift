import AppKit
import SwiftUI

/// Owns the status item and the app's single window.
///
/// The window is built here in AppKit and hosts the SwiftUI view, rather than coming from a
/// `Window` scene. A menu bar app needs a window it can hide and bring back at will, and a scene's
/// lifetime belongs to SwiftUI: once it tears the scene down, the window and everything on it is
/// gone. Owning the window outright means closing it can simply put it away.
///
/// The app is an `LSUIElement`, so it carries no Dock icon of its own and the window *is* the app.
/// While the window is up MicroCast promotes itself to a regular app, so it gets a Dock icon, a
/// menu bar and the usual shortcuts; closing the window demotes it again. That is what keeps it
/// feeling like a utility when it is out of the way and like an application when it is not.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
	static private(set) weak var shared: AppDelegate?

	let streamer = Streamer()
	private var statusItem: NSStatusItem?
	private var window: NSWindow?
	private var running = false

	func applicationDidFinishLaunching(_ notification: Notification) {
		Self.shared = self

		let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		item.button?.image = Self.icon(running: false)
		item.button?.target = self
		item.button?.action = #selector(statusItemClicked)
		item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
		item.button?.toolTip = "MicroCast"
		statusItem = item

		makeWindow()
		showWindow()
		Screenshot.listen { [weak self] in self?.window }
	}

	/// The window is the app's face, not its life: closing it leaves MicroCast in the menu bar.
	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
		showWindow()
		return true
	}

	func setRunning(_ value: Bool) {
		guard value != running else { return }
		running = value
		statusItem?.button?.image = Self.icon(running: value)
	}

	// MARK: Window

	private func makeWindow() {
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
			styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
			backing: .buffered, defer: false)
		window.title = "MicroCast"
		window.delegate = self
		window.isReleasedWhenClosed = false
		window.titlebarAppearsTransparent = true
		window.titleVisibility = .hidden
		window.isMovableByWindowBackground = true
		window.backgroundColor = .clear
		window.minSize = NSSize(width: 480, height: 520)
		// No traffic lights: the status item opens and puts the window away, and ⌘W still works
		// because the window stays closable — the buttons are hidden, not removed from the mask.
		for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
			window.standardWindowButton(button)?.isHidden = true
		}
		window.contentView = NSHostingView(rootView: RootView(streamer: streamer))
		window.center()
		// Remembers where the user put it, across hides and across launches.
		window.setFrameAutosaveName("MicroCastMainWindow")
		self.window = window
	}

	func showWindow() {
		applyActivationPolicy(windowVisible: true)
		NSApp.activate(ignoringOtherApps: true)
		window?.makeKeyAndOrderFront(nil)
	}

	private func hideWindow() {
		window?.orderOut(nil)
		applyActivationPolicy(windowVisible: false)
	}

	private func toggleWindow() {
		if let window, window.isVisible, NSApp.isActive {
			hideWindow()
		} else {
			showWindow()
		}
	}

	/// Closing puts the window away instead of destroying it, so the status item brings back the
	/// very same window, still showing whatever the user was looking at.
	func windowShouldClose(_ sender: NSWindow) -> Bool {
		hideWindow()
		return false
	}

	private func applyActivationPolicy(windowVisible: Bool) {
		NSApp.setActivationPolicy(windowVisible ? .regular : .accessory)
	}

	// MARK: Status item

	@objc private func statusItemClicked() {
		if NSApp.currentEvent?.type == .rightMouseUp {
			showQuickMenu()
		} else {
			toggleWindow()
		}
	}

	/// Right-click keeps the old menu bar reflexes working without opening the window.
	private func showQuickMenu() {
		let menu = NSMenu()
		let toggle = NSMenuItem(
			title: streamer.isRunning ? "Stop streaming" : "Start streaming",
			action: #selector(toggleStream), keyEquivalent: "")
		toggle.target = self
		toggle.isEnabled = !streamer.isStarting
		menu.addItem(toggle)
		if streamer.isRunning, streamer.jingleCount > 0 {
			let jingle = NSMenuItem(title: "Play a jingle", action: #selector(playJingle), keyEquivalent: "")
			jingle.target = self
			menu.addItem(jingle)
		}
		menu.addItem(.separator())
		let open = NSMenuItem(title: "Open MicroCast", action: #selector(openFromMenu), keyEquivalent: "")
		open.target = self
		menu.addItem(open)
		menu.addItem(.separator())
		menu.addItem(NSMenuItem(
			title: "Quit MicroCast", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

		// Attaching the menu makes the button show it; detaching afterwards leaves left-click on
		// our own action rather than on the menu.
		statusItem?.menu = menu
		statusItem?.button?.performClick(nil)
		statusItem?.menu = nil
	}

	@objc private func toggleStream() {
		if streamer.isRunning {
			streamer.stop()
		} else {
			Task { await streamer.start() }
		}
	}

	@objc private func playJingle() {
		streamer.playJingle()
	}

	@objc private func openFromMenu() {
		showWindow()
	}

	private static func icon(running: Bool) -> NSImage? {
		let image = NSImage(
			systemSymbolName: running ? "dot.radiowaves.left.and.right" : "radio",
			accessibilityDescription: running ? "MicroCast, on air" : "MicroCast")
		image?.isTemplate = true
		return image
	}
}
