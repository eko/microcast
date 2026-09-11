import AppKit
import SwiftUI

/// The choices for the status item.
///
/// Each carries a pair: one glyph at rest and a louder one on air, so the menu bar says whether
/// the signal is out without the window being open. Every name is checked against macOS 14's
/// symbol set — a missing one draws nothing at all, which reads as the app having crashed.
enum MenuBarIcon: String, CaseIterable, Identifiable {
	case radio, waveform, antenna, microphone, record, onOff

	var id: String { rawValue }

	var label: String {
		switch self {
		case .radio: "Radio"
		case .waveform: "Waveform"
		case .antenna: "Antenna"
		case .microphone: "Microphone"
		case .record: "Record"
		case .onOff: "On / Off"
		}
	}

	/// The status item's picture for the current state. One place makes it, so the settings row
	/// previews exactly what the menu bar will show.
	func image(live: Bool) -> NSImage? {
		if self == .onOff { return Self.badge(live: live) }
		let image = NSImage(
			systemSymbolName: symbol(live: live),
			accessibilityDescription: live ? "MicroCast, on air" : "MicroCast")
		image?.isTemplate = true
		return image
	}

	private func symbol(live: Bool) -> String {
		switch self {
		case .radio: live ? "dot.radiowaves.left.and.right" : "radio"
		case .waveform: live ? "waveform.circle.fill" : "waveform"
		case .antenna: live ? "antenna.radiowaves.left.and.right.circle.fill" : "antenna.radiowaves.left.and.right"
		case .microphone: live ? "mic.fill" : "mic"
		case .record: live ? "record.circle.fill" : "smallcircle.filled.circle"
		case .onOff: ""
		}
	}

	/// A lettered badge, drawn because SF Symbols has none.
	///
	/// Off air it is an outline around the word; on air the rectangle fills and the word is
	/// knocked out of it, which reads across the menu bar far faster than a change of glyph.
	/// Marked as a template, so macOS tints it correctly on a light or a dark menu bar.
	private static func badge(live: Bool) -> NSImage {
		let text = live ? "ON" : "OFF" as NSString
		let attributes: [NSAttributedString.Key: Any] = [
			.font: NSFont.systemFont(ofSize: 8.5, weight: .bold),
			.foregroundColor: NSColor.black,
			.kern: 0.3,
		]
		let textSize = text.size(withAttributes: attributes)
		// Sized on the longer word, so the status item does not jump a few points wider
		// when the stream stops.
		let widest = ("OFF" as NSString).size(withAttributes: attributes).width
		let size = NSSize(width: ceil(widest) + 9, height: 13)
		let image = NSImage(size: size, flipped: false) { rect in
			let shape = NSBezierPath(
				roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3)
			let origin = NSPoint(
				x: (rect.width - textSize.width) / 2,
				y: (rect.height - textSize.height) / 2)
			NSColor.black.setFill()
			NSColor.black.setStroke()
			if live {
				shape.fill()
				// Punching the word out keeps the badge a single template shape.
				NSGraphicsContext.current?.compositingOperation = .destinationOut
			} else {
				shape.lineWidth = 1.25
				shape.stroke()
			}
			text.draw(at: origin, withAttributes: attributes)
			return true
		}
		image.isTemplate = true
		return image
	}
}

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
	/// Set by the window's view, so the key monitor can drive it when there is no menu bar.
	var onShortcut: ((Shortcut) -> Void)?
	private var statusItem: NSStatusItem?
	private var window: NSWindow?
	private var running = false
	private var shortcutMonitor: Any?
	private var appliedIcon = Settings.menuBarIcon
	private var appliedDock = Settings.showInDock

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

		// Read straight from the defaults rather than being told by a view: the status item and
		// the activation policy live outside SwiftUI, and this catches whichever pane changed them.
		NotificationCenter.default.addObserver(
			forName: UserDefaults.didChangeNotification, object: nil, queue: .main
		) { _ in
			MainActor.assumeIsolated { self.applyPreferences() }
		}
		installShortcutMonitor()
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

	/// Applies the menu bar icon and the Dock preference, whenever either is changed.
	private func applyPreferences() {
		if Settings.menuBarIcon != appliedIcon {
			appliedIcon = Settings.menuBarIcon
			statusItem?.button?.image = Self.icon(running: running)
		}
		if Settings.showInDock != appliedDock {
			appliedDock = Settings.showInDock
			let wasVisible = window?.isVisible ?? false
			applyActivationPolicy()
			// Changing the activation policy orders the app's windows out, so turning the Dock
			// icon off would otherwise look exactly like the app vanishing.
			if wasVisible { showWindow() }
		}
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
		// Opaque on purpose: a see-through window has the compositor re-blend everything beneath
		// it whenever anything there moves, and the ambient field covers every pixel anyway.
		window.isOpaque = true
		window.backgroundColor = .windowBackgroundColor
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
		applyActivationPolicy()
		NSApp.activate(ignoringOtherApps: true)
		window?.makeKeyAndOrderFront(nil)
	}

	private func hideWindow() {
		window?.orderOut(nil)
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

	/// Regular when the Dock icon is wanted, accessory when it is not — fixed either way.
	///
	/// An earlier version flipped this as the window opened and closed. Changing the policy
	/// orders the app's windows out and rebuilds the main menu, which made the window vanish on
	/// the switch and left the keyboard shortcuts working in one mode but not the other. Setting
	/// it once costs a Dock icon while the window is away, and removes both faults.
	private func applyActivationPolicy() {
		NSApp.setActivationPolicy(Settings.showInDock ? .regular : .accessory)
	}

	/// What the key monitor can ask the window to do.
	enum Shortcut { case settings, back, toggleStream }

	/// Handles the window's shortcuts.
	///
	/// SwiftUI routes `keyboardShortcut` through the app's main menu, but this window is an
	/// AppKit one hosting SwiftUI, and the menu is rebuilt whenever the activation policy
	/// changes — so the shortcuts worked in one Dock mode and not the other. Owning them here
	/// makes the behaviour the same either way. Only Return defers to a focused text field.
	private func installShortcutMonitor() {
		shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			// Local monitors arrive on the main thread. Only the two primitives cross the
			// isolation boundary, because NSEvent itself is not Sendable.
			let command = event.modifierFlags.contains(.command)
			let characters = event.charactersIgnoringModifiers ?? ""
			let handled = MainActor.assumeIsolated {
				self?.handle(command: command, characters: characters) ?? false
			}
			return handled ? nil : event
		}
	}

	private func handle(command: Bool, characters: String) -> Bool {
		// Only Return defers to a text field. Guarding every shortcut that way was too broad:
		// entering settings gives a field the keyboard, which then swallowed ⌘W as well.
		let typing = window?.firstResponder is NSTextView
		switch (command, characters) {
		case (true, ","): onShortcut?(.settings)
		case (true, "w"): hideWindow()
		case (true, "q"): NSApp.terminate(nil)
		case (false, "\u{1b}"): onShortcut?(.back)
		case (false, "\r"):
			guard !typing else { return false }
			onShortcut?(.toggleStream)
		default: return false
		}
		return true
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
		Settings.menuBarIcon.image(live: running)
	}
}
