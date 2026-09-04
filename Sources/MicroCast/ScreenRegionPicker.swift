import AppKit

/// A translucent full-screen overlay to drag out a capture rectangle, returning it in display points, top-left origin.
final class ScreenRegionPicker {
	private final class SelectionView: NSView {
		var onFinish: ((NSRect?) -> Void)?
		private var start: NSPoint?
		private var current: NSRect = .zero

		override var acceptsFirstResponder: Bool { true }
		override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil); current = .zero; needsDisplay = true }
		override func mouseDragged(with event: NSEvent) {
			guard let start else { return }
			let point = convert(event.locationInWindow, from: nil)
			current = NSRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
			needsDisplay = true
		}
		override func mouseUp(with event: NSEvent) { onFinish?(current.width > 8 && current.height > 8 ? current : nil) }
		override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onFinish?(nil) } } // Esc

		override func draw(_ dirtyRect: NSRect) {
			NSColor.black.withAlphaComponent(0.28).setFill()
			dirtyRect.fill()
			guard current.width > 0 else { return }
			NSColor.clear.setFill()
			current.fill(using: .copy)
			NSColor.controlAccentColor.setStroke()
			let path = NSBezierPath(rect: current); path.lineWidth = 2; path.stroke()
		}
	}

	private var window: NSWindow?

	/// Shows the overlay on `screen`; calls back with the region in that display's points, or nil if cancelled.
	func present(on screen: NSScreen, completion: @escaping (ScreenRegion?) -> Void) {
		let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
		window.level = .screenSaver
		window.backgroundColor = .clear
		window.isOpaque = false
		window.ignoresMouseEvents = false
		let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
		let displayHeight = screen.frame.height
		view.onFinish = { [weak self] rect in
			self?.window?.orderOut(nil)
			self?.window = nil
			guard let rect else { completion(nil); return }
			// AppKit is bottom-left; sourceRect is top-left of the display.
			let region = ScreenRegion(
				x: Int(rect.minX.rounded()),
				y: Int((displayHeight - rect.maxY).rounded()),
				width: Int(rect.width.rounded()),
				height: Int(rect.height.rounded())
			)
			completion(region)
		}
		window.contentView = view
		window.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
		window.makeFirstResponder(view)
		self.window = window
	}
}
