import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Copies text to the pasteboard and confirms with a checkmark for a moment.
struct CopyButton: View {
	let text: String
	@State private var copied = false

	var body: some View {
		Button {
			NSPasteboard.general.clearContents()
			NSPasteboard.general.setString(text, forType: .string)
			withAnimation(.easeOut(duration: 0.15)) { copied = true }
			Task {
				try? await Task.sleep(for: .seconds(1.4))
				withAnimation { copied = false }
			}
		} label: {
			Image(systemName: copied ? "checkmark" : "doc.on.doc")
				.foregroundStyle(copied ? Color.green : Color.muted)
				.contentTransition(.symbolEffect(.replace))
		}
		.buttonStyle(.borderless)
		.help(copied ? "Copied" : "Copy")
	}
}

@MainActor
enum QRCode {
	private static var cache: (url: URL, image: NSImage)?

	/// The code for `url`, rendered once and kept.
	///
	/// Memoised here rather than in the view: this is a Core Image render, far too expensive to
	/// repeat on every view update, and holding it in view state made it depend on when exactly
	/// SwiftUI decided to run a task — which is how it ended up missing from the panel entirely.
	static func cached(for url: URL) -> NSImage? {
		if let cache, cache.url == url { return cache.image }
		guard let image = image(for: url) else { return nil }
		cache = (url, image)
		return image
	}

	/// A black-on-white QR image for `url`.
	static func image(for url: URL, side: CGFloat = 96) -> NSImage? {
		let filter = CIFilter.qrCodeGenerator()
		filter.message = Data(url.absoluteString.utf8)
		filter.correctionLevel = "M"
		guard let output = filter.outputImage else { return nil }
		let scale = side * 2 / output.extent.width
		let representation = NSCIImageRep(ciImage: output.transformed(by: CGAffineTransform(scaleX: scale, y: scale)))
		let image = NSImage(size: NSSize(width: side, height: side))
		image.addRepresentation(representation)
		return image
	}
}

/// A tinted, rounded message with an optional action, for warnings and states worth acting on.
struct Banner: View {
	enum Kind { case info, warning, error }

	let kind: Kind
	let symbol: String
	let message: String
	var actionTitle: String? = nil
	var action: (() -> Void)? = nil

	var body: some View {
		HStack(spacing: 8) {
			Image(systemName: symbol).foregroundStyle(tint)
			Text(message)
				.font(.callout)
				.fixedSize(horizontal: false, vertical: true)
			Spacer(minLength: 0)
			if let actionTitle, let action {
				Button(actionTitle, action: action)
					.controlSize(.small)
			}
		}
		.padding(10)
		.background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
	}

	private var tint: Color {
		switch kind {
		case .info: .accentColor
		case .warning: .orange
		case .error: .red
		}
	}
}

/// Small uppercase section title, as in Apple's own popovers.
struct SectionTitle: View {
	let text: String

	var body: some View {
		Text(text.uppercased())
			.font(.system(size: 10, weight: .semibold))
			.kerning(0.6)
			.foregroundStyle(.muted)
	}
}

enum SystemSettings {
	static func openMicrophonePrivacy() {
		if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
			NSWorkspace.shared.open(url)
		}
	}
}

/// The transmit key.
///
/// A console button rather than a form button: one flat colour, with the depth coming from a ring
/// and a soft coloured shadow instead of a gradient. Gloss and rim lights were the wrong idea here
/// — they read as Aqua, not as equipment. The ring carries the state: accent while it waits, a
/// turning arc while the encoders come up, red and thicker once the signal is out.
struct BroadcastButton: View {
	var live: Bool
	var starting: Bool
	var blocked: Bool
	var action: () -> Void

	@State private var hovering = false
	@State private var spinning = false

	private var tint: Color { live ? .red : .accentColor }
	private var enabled: Bool { !blocked && !starting }
	private var ringWidth: CGFloat { live ? 4 : 3 }

	var body: some View {
		VStack(spacing: 11) {
			Button(action: action) { face }
				.buttonStyle(PressScale())
				.keyboardShortcut(.defaultAction)
				.disabled(!enabled)
				.onHover { hovering = $0 && enabled }
				.help(title)
			caption
		}
		.frame(maxWidth: .infinity)
		.saturation(blocked ? 0.1 : 1)
		.opacity(blocked ? 0.5 : 1)
		.animation(.spring(response: 0.34, dampingFraction: 0.8), value: live)
		.animation(.easeOut(duration: 0.18), value: hovering)
		.onChange(of: starting, initial: true) { _, value in spinning = value }
	}

	private var face: some View {
		ZStack {
			if live {
				RadarRings(tint: tint)
					.frame(width: 92, height: 92)
					.allowsHitTesting(false)
			}

			// The track the ring sits in, so the arc has something to travel along.
			Circle()
				.stroke(tint.opacity(0.22), lineWidth: ringWidth)
				.frame(width: 92, height: 92)

			if starting {
				Circle()
					.trim(from: 0, to: 0.3)
					.stroke(tint, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
					.frame(width: 92, height: 92)
					.rotationEffect(.degrees(spinning ? 360 : 0))
					.animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
			} else {
				Circle()
					.stroke(tint, lineWidth: ringWidth)
					.frame(width: 92, height: 92)
			}

			Circle()
				.fill(tint)
				.frame(width: 72, height: 72)
				.shadow(color: tint.opacity(hovering ? 0.55 : 0.32),
				        radius: hovering ? 20 : 13, y: 6)

			Image(systemName: live ? "stop.fill" : "play.fill")
				.font(.system(size: 25, weight: .medium))
				.foregroundStyle(.white)
				// A triangle's visual centre sits left of its bounding box; nudge it back.
				.offset(x: live ? 0 : 2)
				.contentTransition(.symbolEffect(.replace))
		}
		.scaleEffect(hovering ? 1.02 : 1)
		.contentShape(Circle())
	}

	private var caption: some View {
		HStack(spacing: 6) {
			Text(title)
				.font(.system(size: 13, weight: .medium, design: .rounded))
				.foregroundStyle(.muted)
			if enabled {
				// The shortcut, shown where the shortcut is: nobody reads a tooltip.
				Image(systemName: "return")
					.font(.system(size: 10, weight: .semibold))
					.foregroundStyle(.faint)
			}
		}
	}

	private var title: String {
		if starting { return "Starting…" }
		return live ? "Stop streaming" : "Start streaming"
	}

	private struct PressScale: ButtonStyle {
		func makeBody(configuration: Configuration) -> some View {
			configuration.label
				.scaleEffect(configuration.isPressed ? 0.93 : 1)
				.animation(.spring(response: 0.24, dampingFraction: 0.6), value: configuration.isPressed)
		}
	}
}

/// Two rings swelling out of the transmit key and fading while the signal is out: the broadcast
/// metaphor. Core Animation runs them. As a SwiftUI animation they had the view graph re-render
/// the window on every frame for as long as the stream lasted, which is most of a core's time.
private struct RadarRings: NSViewRepresentable {
	var tint: Color

	func makeNSView(context: Context) -> PulseRingsView { PulseRingsView(tint: NSColor(tint)) }

	func updateNSView(_ view: PulseRingsView, context: Context) { view.tint = NSColor(tint) }
}

final class PulseRingsView: NSView {
	private let rings = [CALayer(), CALayer()]

	var tint: NSColor {
		didSet { for ring in rings { ring.borderColor = tint.cgColor } }
	}

	init(tint: NSColor) {
		self.tint = tint
		super.init(frame: .zero)
		wantsLayer = true
		for ring in rings {
			ring.borderWidth = 1.5
			ring.borderColor = tint.cgColor
			ring.opacity = 0 // invisible until its animation begins
			layer?.addSublayer(ring)
		}
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("not used") }

	override func layout() {
		super.layout()
		let side = min(bounds.width, bounds.height)
		guard side > 0 else { return }
		let circle = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
		// Decorative, so it is the first thing to go under Reduce Motion.
		guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
		for (index, ring) in rings.enumerated() {
			ring.frame = circle.insetBy(dx: 1, dy: 1)
			ring.cornerRadius = ring.bounds.width / 2
			ring.removeAllAnimations()
			ring.add(Self.swell(delay: Double(index) * 1.2), forKey: "swell")
		}
	}

	private static func swell(delay: Double) -> CAAnimation {
		let scale = CABasicAnimation(keyPath: "transform.scale")
		scale.fromValue = 1
		scale.toValue = 1.7
		let fade = CABasicAnimation(keyPath: "opacity")
		fade.fromValue = 0.55
		fade.toValue = 0
		let group = CAAnimationGroup()
		group.animations = [scale, fade]
		group.duration = 2.4
		group.timingFunction = CAMediaTimingFunction(name: .easeOut)
		group.repeatCount = .infinity
		group.beginTime = CACurrentMediaTime() + delay
		return group.cappedAtSixty()
	}
}

// MARK: - Window chrome

/// The window's colour field: a tinted base with three broad glows drifting across it.
///
/// One flat gradient reads as a grey wash; overlapping radial glows at different sizes give the
/// background depth, and moving them slowly keeps the window alive without asking for attention.
/// The palette turns from cool to warm the moment the stream goes out, so the window's colour says
/// what it is doing from across the room. Light and dark are separate palettes rather than one set
/// of colours at two opacities: what reads as a soft tint on white turns to mud on black.
///
/// The field is opaque, and so is the window. It used to sit at nine tenths opacity on a blur
/// of the desktop, which left the blur all but invisible while the compositor still recomputed
/// it, and every card's material over it, each time anything on the screen moved. That cost
/// WindowServer a third of a core with the app idle, and showed as stutter across the whole Mac.
struct AmbientBackground: View {
	var live: Bool
	@Environment(\.colorScheme) private var scheme

	var body: some View {
		GeometryReader { proxy in
			let width = proxy.size.width
			let height = proxy.size.height
			let colours = palette
			ZStack {
				colours.base
				glow(colours.first, x: 0.16, y: 0.06, scale: 0.95, width: width, height: height)
				glow(colours.second, x: 0.94, y: 0.34, scale: 0.80, width: width, height: height)
				glow(colours.third, x: 0.38, y: 0.98, scale: 1.05, width: width, height: height)
			}
			// A radial gradient that fades to clear is already perfectly smooth, so there is
			// nothing for a blur to soften — and no drift, because animating this field meant
			// recompositing the whole window sixty times a second for a motion nobody watches.
			// Drawn once and cached; the only repaint is when the palette flips on air.
			.drawingGroup()
		}
		.allowsHitTesting(false)
		.animation(.easeInOut(duration: 1.1), value: live)
	}

	private func glow(_ colour: Color, x: CGFloat, y: CGFloat, scale: CGFloat,
	                  width: CGFloat, height: CGFloat) -> some View {
		let side = max(width, height) * scale
		return Circle()
			.fill(RadialGradient(
				colors: [colour, colour.opacity(0)],
				center: .center, startRadius: 0, endRadius: side / 2))
			.frame(width: side, height: side)
			.position(x: width * x, y: height * y)
	}

	private var palette: (base: Color, first: Color, second: Color, third: Color) {
		switch (scheme, live) {
		case (.dark, false):
			// Deep indigo night: saturated enough to be a colour, dark enough to read white text on.
			(Color(red: 0.055, green: 0.063, blue: 0.098),
			 Color(red: 0.28, green: 0.32, blue: 0.88).opacity(0.60),
			 Color(red: 0.56, green: 0.24, blue: 0.78).opacity(0.48),
			 Color(red: 0.10, green: 0.52, blue: 0.62).opacity(0.44))
		case (.dark, true):
			(Color(red: 0.095, green: 0.042, blue: 0.055),
			 Color(red: 0.88, green: 0.15, blue: 0.28).opacity(0.58),
			 Color(red: 0.96, green: 0.45, blue: 0.10).opacity(0.46),
			 Color(red: 0.54, green: 0.08, blue: 0.34).opacity(0.48))
		case (_, false):
			// Daylight: pale tints on near-white, kept weak so dark text stays comfortable.
			(Color(red: 0.965, green: 0.972, blue: 0.992),
			 Color(red: 0.40, green: 0.60, blue: 0.99).opacity(0.42),
			 Color(red: 0.72, green: 0.58, blue: 0.99).opacity(0.34),
			 Color(red: 0.40, green: 0.86, blue: 0.80).opacity(0.30))
		case (_, true):
			(Color(red: 0.996, green: 0.968, blue: 0.958),
			 Color(red: 1.00, green: 0.42, blue: 0.40).opacity(0.44),
			 Color(red: 1.00, green: 0.72, blue: 0.32).opacity(0.38),
			 Color(red: 0.98, green: 0.52, blue: 0.70).opacity(0.32))
		}
	}
}

// MARK: - Surfaces

/// A raised, translucent panel. Everything on the dashboard sits in one of these, which is what
/// gives the window a rhythm instead of a wall of controls.
///
/// Glass by arithmetic rather than by material. The field behind every card is a smooth gradient,
/// and a blur of a smooth gradient is that same gradient, so a translucent tint over it looks
/// exactly as a material would — and lets the field show through as it warms up on air. It costs
/// the compositor one plain fill, where a material is a backdrop layer re-rendered every time
/// anything beneath it changes.
struct Card<Content: View>: View {
	var padding: CGFloat = 16
	@ViewBuilder var content: Content
	@Environment(\.colorScheme) private var scheme

	private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 18, style: .continuous) }

	private var glass: Color {
		scheme == .dark
			? Color(red: 0.10, green: 0.10, blue: 0.11).opacity(0.72)
			: Color.white.opacity(0.62)
	}

	var body: some View {
		content
			.padding(padding)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background {
				shape.fill(glass)
					// The shadow hangs off this static backing rather than the card as a whole:
					// there it was recomputed from the content every time a meter moved.
					.shadow(color: .black.opacity(0.16), radius: 10, y: 4)
			}
			.overlay {
				shape.strokeBorder(
					LinearGradient(
						colors: [Color.white.opacity(0.40), Color.white.opacity(0.05)],
						startPoint: .top, endPoint: .bottom),
					lineWidth: 1)
			}
	}
}

/// The on-air badge: a dot that breathes, with a ripple leaving it, so the state reads from the
/// corner of the eye. The motion is Core Animation's, for the same reason as the rings.
struct LivePill: View {
	var body: some View {
		HStack(spacing: 5) {
			PulseDot()
				.frame(width: 6, height: 6)
			Text("ON AIR")
				.font(.system(size: 10, weight: .bold, design: .rounded))
				.kerning(0.6)
		}
		.foregroundStyle(.white)
		.padding(.horizontal, 9)
		.padding(.vertical, 4)
		.background(
			LinearGradient(colors: [.red, Color(red: 0.85, green: 0.15, blue: 0.3)],
						   startPoint: .top, endPoint: .bottom),
			in: Capsule()
		)
		.shadow(color: .red.opacity(0.4), radius: 6, y: 2)
	}
}

private struct PulseDot: NSViewRepresentable {
	func makeNSView(context: Context) -> PulseDotView { PulseDotView() }

	func updateNSView(_ view: PulseDotView, context: Context) {}
}

final class PulseDotView: NSView {
	private let ripple = CALayer()
	private let dot = CALayer()

	init() {
		super.init(frame: .zero)
		wantsLayer = true
		for disc in [ripple, dot] {
			disc.backgroundColor = NSColor.white.cgColor
			layer?.addSublayer(disc)
		}
		ripple.opacity = 0
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("not used") }

	override func layout() {
		super.layout()
		let side = min(bounds.width, bounds.height)
		guard side > 0 else { return }
		let circle = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
		for disc in [ripple, dot] {
			disc.frame = circle
			disc.cornerRadius = side / 2
			disc.removeAllAnimations()
		}
		guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
		let scale = CABasicAnimation(keyPath: "transform.scale")
		scale.fromValue = 1
		scale.toValue = 2.8
		let fade = CABasicAnimation(keyPath: "opacity")
		fade.fromValue = 0.7
		fade.toValue = 0
		let leave = CAAnimationGroup()
		leave.animations = [scale, fade]
		leave.duration = 1.6
		leave.timingFunction = CAMediaTimingFunction(name: .easeOut)
		leave.repeatCount = .infinity
		ripple.add(leave.cappedAtSixty(), forKey: "ripple")
		let breath = CABasicAnimation(keyPath: "opacity")
		breath.fromValue = 1
		breath.toValue = 0.5
		breath.duration = 0.9
		breath.autoreverses = true
		breath.repeatCount = .infinity
		breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
		dot.add(breath.cappedAtSixty(), forKey: "breath")
	}
}

/// One number with its label, for the row of vitals under the hero.
struct StatTile: View {
	let value: String
	let label: String
	var symbol: String? = nil

	var body: some View {
		VStack(alignment: .leading, spacing: 3) {
			HStack(spacing: 4) {
				if let symbol {
					Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(.faint)
				}
				Text(label.uppercased())
					.font(.system(size: 9, weight: .semibold))
					.kerning(0.5)
					.foregroundStyle(.faint)
			}
			Text(value)
				.font(.system(size: 17, weight: .semibold, design: .rounded))
				.monospacedDigit()
				.lineLimit(1)
				.minimumScaleFactor(0.7)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

/// A quiet, round icon button for the title bar.
struct ChromeButtonStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.font(.system(size: 13, weight: .medium))
			.foregroundStyle(.muted)
			.frame(width: 26, height: 26)
			.background(
				Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.06))
			)
			.contentShape(Circle())
	}
}

// MARK: - Motion

extension CAAnimation {
	/// Sixty frames a second is plenty for a meter; on a ProMotion display the default would be
	/// a hundred and twenty, twice the compositor's work for nothing anyone can see. Thirty when
	/// the user has asked the system for less motion.
	func cappedAtSixty() -> Self {
		let top: Float = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 30 : 60
		preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: top, preferred: top)
		return self
	}
}

// MARK: - Waveform

enum AudioScale {
	/// Where a linear amplitude sits on a 60 dB scale, 0 at the floor and 1 at full scale.
	/// Meters are read in decibels: on a linear scale everything but the loudest peaks hugs zero.
	static func fraction(_ level: Float) -> Float {
		guard level > 0 else { return 0 }
		return min(1, max(0, (20 * log10(level) + 60) / 60))
	}
}

/// A rolling window over the recent output level, both channels.
///
/// The meter publishes twenty times a second, so keeping the last few seconds of it costs almost
/// nothing. Written into a ring buffer: overwriting one slot beats shifting an array twenty times
/// a second, and the drawing reads it oldest first through `frame(at:)`.
final class LevelTrace {
	struct Frame {
		var left: Float
		var right: Float
	}

	static let capacity = 72
	/// Seconds between samples; the meter timer in `Streamer` runs at this rate.
	static let interval: TimeInterval = 0.05

	private var frames = [Frame](repeating: Frame(left: 0, right: 0), count: capacity)
	private var head = 0

	/// Oldest at 0, newest at `capacity - 1`.
	func frame(at index: Int) -> Frame { frames[(head + index) % Self.capacity] }

	func push(left: Float, right: Float) {
		frames[head] = Frame(left: left, right: right)
		head = (head + 1) % Self.capacity
	}

	func clear() {
		frames = [Frame](repeating: Frame(left: 0, right: 0), count: Self.capacity)
		head = 0
	}
}

/// The one sound picture: a glowing stereo waveform gliding right to left, with peak-hold marks.
///
/// Left runs above the centre line and right below it, so one drawing carries the shape of the
/// sound over time *and* which channel is doing what. It is a handful of Core Animation layers:
/// twenty times a second the meter hands them the next path and a slide of one step, and the
/// display moves them at its own refresh rate. Fed straight from the streamer's meter rather than
/// through SwiftUI, so the view graph is not re-evaluated on every reading; drawn in SwiftUI, it
/// was re-rendered on every frame — a third of a core for one small rectangle.
struct SignalTrace: NSViewRepresentable {
	var streamer: Streamer
	var live: Bool

	@MainActor
	final class Coordinator {
		private weak var streamer: Streamer?

		func attach(_ view: WaveformView, to streamer: Streamer) {
			self.streamer = streamer
			streamer.meterSink = { [weak view] left, right, peakLeft, peakRight in
				view?.push(left: left, right: right, peakLeft: peakLeft, peakRight: peakRight)
			}
		}

		func detach() {
			streamer?.meterSink = nil
			streamer = nil
		}
	}

	func makeCoordinator() -> Coordinator { Coordinator() }

	func makeNSView(context: Context) -> WaveformView {
		let view = WaveformView()
		context.coordinator.attach(view, to: streamer)
		return view
	}

	func updateNSView(_ view: WaveformView, context: Context) {
		view.live = live
	}

	static func dismantleNSView(_ nsView: WaveformView, coordinator: Coordinator) {
		coordinator.detach()
	}
}

/// The layers behind `SignalTrace`.
///
/// The path holds one sample per step from the left edge to one step past the right edge. Each
/// reading swaps in the next path — the same curve one step further on, with the new sample
/// waiting beyond the edge — and slides the group by one step over one interval, starting from
/// wherever the previous slide had got to. The two states coincide, so nothing ever jumps; the
/// newest sample simply glides into view. Every layer is a plain shape or gradient, nothing the
/// compositor has to blur.
final class WaveformView: NSView {
	private let trace = LevelTrace()
	private let group = CALayer()
	private let bodyLayer = CAGradientLayer()
	private let bodyMask = CAShapeLayer()
	private let softGlow = CAShapeLayer()
	private let tightGlow = CAShapeLayer()
	private let edge = CAShapeLayer()
	private let centre = CALayer()
	private let leftMark = CAGradientLayer()
	private let rightMark = CAGradientLayer()
	private var peaks: (left: Float, right: Float) = (0, 0)
	private var shapes: [CAShapeLayer] { [softGlow, tightGlow, edge, bodyMask] }

	var live = false {
		didSet { if live != oldValue { applyColours(duration: 1.1) } }
	}

	override var isFlipped: Bool { true }

	override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		for shape in shapes {
			shape.fillColor = nil
			shape.lineCap = .round
			shape.lineJoin = .round
		}
		softGlow.lineWidth = 10
		tightGlow.lineWidth = 4
		edge.lineWidth = 0.8
		bodyMask.fillColor = NSColor.black.cgColor
		bodyLayer.mask = bodyMask
		bodyLayer.startPoint = CGPoint(x: 0.5, y: 0)
		bodyLayer.endPoint = CGPoint(x: 0.5, y: 1)
		for mark in [leftMark, rightMark] {
			mark.startPoint = CGPoint(x: 0, y: 0.5)
			mark.endPoint = CGPoint(x: 1, y: 0.5)
		}
		for sublayer in [softGlow, tightGlow, bodyLayer, edge] { group.addSublayer(sublayer) }
		for sublayer in [centre, group, leftMark, rightMark] { layer?.addSublayer(sublayer) }
		layer?.masksToBounds = true
		applyColours(duration: 0)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("not used") }

	override func viewDidChangeBackingProperties() {
		super.viewDidChangeBackingProperties()
		let scale = window?.backingScaleFactor ?? 2
		for shape in shapes { shape.contentsScale = scale }
	}

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		applyColours(duration: 0)
	}

	override func layout() {
		super.layout()
		guard bounds.width > 0, bounds.height > 0 else { return }
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		group.frame = bounds
		for sublayer in [softGlow, tightGlow, bodyLayer, bodyMask, edge] { sublayer.frame = bounds }
		centre.frame = CGRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1)
		for mark in [leftMark, rightMark] {
			mark.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
			mark.position.x = bounds.midX
		}
		group.removeAnimation(forKey: "slide")
		let path = makePath()
		for shape in shapes { shape.path = path }
		placeMarks(animated: false)
		CATransaction.commit()
	}

	/// Takes a reading: the next path, and a slide of one step over one interval.
	func push(left: Float, right: Float, peakLeft: Float, peakRight: Float) {
		trace.push(left: left, right: right)
		peaks = (peakLeft, peakRight)
		guard bounds.width > 0 else { return }
		let step = self.step
		let travelled = (group.presentation() ?? group).value(forKeyPath: "transform.translation.x") as? CGFloat ?? -step
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		let path = makePath()
		for shape in shapes { shape.path = path }
		let slide = CABasicAnimation(keyPath: "transform.translation.x")
		slide.fromValue = travelled + step
		slide.toValue = -step
		slide.duration = LevelTrace.interval
		slide.timingFunction = CAMediaTimingFunction(name: .linear)
		slide.fillMode = .forwards
		slide.isRemovedOnCompletion = false
		group.add(slide.cappedAtSixty(), forKey: "slide")
		CATransaction.commit()
		placeMarks(animated: true)
	}

	private var step: CGFloat { bounds.width / CGFloat(LevelTrace.capacity - 2) }

	/// Oldest sample at the left edge, newest one step past the right edge.
	private func makePath() -> CGPath {
		let count = LevelTrace.capacity
		let middle = bounds.midY
		let reach = middle - 3 // headroom, so the glow is not cut at the edges
		let floor: CGFloat = 1.2 // a carrier line stays visible through silence
		let step = self.step
		var upper: [CGPoint] = []
		var lower: [CGPoint] = []
		upper.reserveCapacity(count)
		lower.reserveCapacity(count)
		// The oldest third settles into the centre line as it leaves: a fade without a mask layer,
		// which would cost the compositor an off-screen pass on every frame.
		let fading = CGFloat(count) * 0.32
		for index in 0..<count {
			let frame = trace.frame(at: index)
			let x = CGFloat(index) * step
			let t = min(1, CGFloat(index) / fading)
			let taper = t * t * (3 - 2 * t)
			upper.append(CGPoint(x: x, y: middle - max(floor, CGFloat(AudioScale.fraction(frame.left)) * reach * taper)))
			lower.append(CGPoint(x: x, y: middle + max(floor, CGFloat(AudioScale.fraction(frame.right)) * reach * taper)))
		}
		let path = CGMutablePath()
		path.move(to: upper[0])
		Self.appendSmooth(path, through: upper) { min($0, middle - floor) }
		path.addLine(to: lower[count - 1])
		Self.appendSmooth(path, through: Array(lower.reversed())) { max($0, middle + floor) }
		path.closeSubpath()
		return path
	}

	/// Catmull-Rom through the points as cubic Béziers, continuing from the path's current point
	/// (the first of them). `clampY` keeps control points from overshooting the centre line.
	private static func appendSmooth(_ path: CGMutablePath, through points: [CGPoint], clampY: (CGFloat) -> CGFloat) {
		guard points.count > 1 else { return }
		for index in 0..<(points.count - 1) {
			let p0 = points[max(index - 1, 0)]
			let p1 = points[index]
			let p2 = points[index + 1]
			let p3 = points[min(index + 2, points.count - 1)]
			let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: clampY(p1.y + (p2.y - p0.y) / 6))
			let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: clampY(p2.y - (p3.y - p1.y) / 6))
			path.addCurve(to: p2, control1: c1, control2: c2)
		}
	}

	/// Peak-hold marks, eased over two intervals so they float rather than step.
	private func placeMarks(animated: Bool) {
		let reach = bounds.midY - 3
		let targets = [
			(leftMark, bounds.midY - CGFloat(AudioScale.fraction(peaks.left)) * reach, peaks.left > 0.98),
			(rightMark, bounds.midY + CGFloat(AudioScale.fraction(peaks.right)) * reach, peaks.right > 0.98),
		]
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		for (mark, y, hot) in targets {
			if animated {
				let move = CABasicAnimation(keyPath: "position.y")
				move.fromValue = (mark.presentation() ?? mark).position.y
				move.toValue = y
				move.duration = LevelTrace.interval * 2
				move.timingFunction = CAMediaTimingFunction(name: .easeOut)
				mark.add(move.cappedAtSixty(), forKey: "float")
			}
			mark.position.y = y
			mark.colors = markColours(hot: hot)
		}
		CATransaction.commit()
	}

	private func applyColours(duration: CFTimeInterval) {
		effectiveAppearance.performAsCurrentDrawingAppearance {
			CATransaction.begin()
			CATransaction.setDisableActions(duration == 0)
			CATransaction.setAnimationDuration(duration)
			let colours = palette
			bodyLayer.colors = colours.body.map(\.cgColor)
			softGlow.strokeColor = colours.glow.withAlphaComponent(0.18).cgColor
			tightGlow.strokeColor = colours.glow.withAlphaComponent(0.30).cgColor
			edge.strokeColor = NSColor.white.withAlphaComponent(0.22).cgColor
			centre.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
			leftMark.colors = markColours(hot: peaks.left > 0.98)
			rightMark.colors = markColours(hot: peaks.right > 0.98)
			CATransaction.commit()
		}
	}

	private var palette: (body: [NSColor], glow: NSColor) {
		if live {
			let amber = NSColor(red: 1.00, green: 0.66, blue: 0.24, alpha: 1)
			let rose = NSColor(red: 1.00, green: 0.27, blue: 0.36, alpha: 1)
			return ([amber, rose, amber], NSColor(red: 1.00, green: 0.30, blue: 0.40, alpha: 1))
		}
		let accent = NSColor.controlAccentColor
		return ([accent.withAlphaComponent(0.75), accent.withAlphaComponent(0.55), accent.withAlphaComponent(0.75)], accent)
	}

	private func markColours(hot: Bool) -> [CGColor] {
		let colour = hot ? NSColor.systemRed : NSColor.labelColor
		return [colour.withAlphaComponent(0).cgColor, colour.withAlphaComponent(hot ? 0.9 : 0.45).cgColor]
	}
}

// MARK: - VU meters

/// A pair of analogue VU meters, left and right, as Core Animation layers.
///
/// The face is drawn once with Core Graphics; the needle is a layer that turns. Each reading
/// swings it towards the new value over 300 ms — the ballistics of a real VU movement — from
/// wherever it is at that moment, so twenty readings a second become one continuous, damped
/// motion and the display does the work between them. Zero VU sits at −3 dBFS on the peak
/// reading, which puts a loud, processed stream riding just under the red the way a station's
/// meters do, and leaves quieter material room to move.
struct VUMeters: NSViewRepresentable {
	var streamer: Streamer
	var live: Bool

	@MainActor
	final class Coordinator {
		private weak var streamer: Streamer?

		func attach(_ view: VUMetersView, to streamer: Streamer) {
			self.streamer = streamer
			streamer.meterSink = { [weak view] left, right, peakLeft, peakRight in
				view?.push(left: left, right: right, peakLeft: peakLeft, peakRight: peakRight)
			}
		}

		func detach() {
			streamer?.meterSink = nil
			streamer = nil
		}
	}

	func makeCoordinator() -> Coordinator { Coordinator() }

	func makeNSView(context: Context) -> VUMetersView {
		let view = VUMetersView()
		context.coordinator.attach(view, to: streamer)
		return view
	}

	func updateNSView(_ view: VUMetersView, context: Context) {
		view.live = live
	}

	static func dismantleNSView(_ nsView: VUMetersView, coordinator: Coordinator) {
		coordinator.detach()
	}
}

final class VUMetersView: NSView {
	private let left = VUMeterLayer(channel: "L")
	private let right = VUMeterLayer(channel: "R")

	var live = false {
		didSet { if live != oldValue { left.setLive(live); right.setLive(live) } }
	}

	override var isFlipped: Bool { true }

	init() {
		super.init(frame: .zero)
		wantsLayer = true
		layer?.addSublayer(left)
		layer?.addSublayer(right)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("not used") }

	override func viewDidChangeBackingProperties() {
		super.viewDidChangeBackingProperties()
		needsLayout = true
	}

	override func layout() {
		super.layout()
		let gap: CGFloat = 14
		let width = (bounds.width - gap) / 2
		guard width > 40, bounds.height > 40 else { return }
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		left.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
		right.frame = CGRect(x: width + gap, y: 0, width: width, height: bounds.height)
		let scale = window?.backingScaleFactor ?? 2
		left.rebuild(scale: scale)
		right.rebuild(scale: scale)
		CATransaction.commit()
	}

	func push(left levelLeft: Float, right levelRight: Float, peakLeft: Float, peakRight: Float) {
		left.swing(to: levelLeft, hot: peakLeft > 0.98)
		right.swing(to: levelRight, hot: peakRight > 0.98)
	}
}

/// One meter: face, backlight, needle and peak lamp.
final class VUMeterLayer: CALayer {
	private let channel: String
	private let face = CALayer()
	private let backlight = CAGradientLayer()
	private let needleGroup = CALayer()
	private let needleShadow = CAShapeLayer()
	private let needle = CAShapeLayer()
	private let lamp = CALayer()
	private var live = false

	/// The scale of a VU meter is not linear in decibels: it opens up towards zero. These are
	/// the standard positions along the arc, −20 at the left stop and +3 at the right.
	private static let anchors: [(vu: Double, fraction: Double)] = [
		(-20, 0.00), (-10, 0.26), (-7, 0.36), (-5, 0.45), (-3, 0.56), (-2, 0.63),
		(-1, 0.70), (0, 0.77), (1, 0.85), (2, 0.92), (3, 1.00),
	]
	private static let span = 88.0 * .pi / 180

	init(channel: String) {
		self.channel = channel
		super.init()
		masksToBounds = true
		cornerRadius = 10
		backlight.type = .radial
		backlight.startPoint = CGPoint(x: 0.5, y: 0.95)
		backlight.endPoint = CGPoint(x: 1.05, y: 0.15)
		backlight.colors = [
			NSColor(red: 1.00, green: 0.62, blue: 0.22, alpha: 0.30).cgColor,
			NSColor(red: 1.00, green: 0.35, blue: 0.30, alpha: 0.10).cgColor,
			NSColor.clear.cgColor,
		]
		backlight.opacity = 0
		needle.fillColor = NSColor(red: 0.98, green: 0.93, blue: 0.84, alpha: 1).cgColor
		// A second, darker needle a touch below stands in for a shadow: a shadow filter would be
		// re-rendered off screen on every frame the needle moves.
		needleShadow.fillColor = NSColor.black.withAlphaComponent(0.55).cgColor
		needleGroup.addSublayer(needleShadow)
		needleGroup.addSublayer(needle)
		lamp.backgroundColor = NSColor(red: 1.0, green: 0.22, blue: 0.20, alpha: 1).cgColor
		lamp.opacity = 0.18
		for sublayer in [face, backlight, needleGroup, lamp] { addSublayer(sublayer) }
	}

	@available(*, unavailable)
	override init(layer: Any) { fatalError("not used") }

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("not used") }

	private var pivot: CGPoint { CGPoint(x: bounds.midX, y: bounds.height * 1.30) }
	private var radius: CGFloat { bounds.height * 1.13 }
	private var arcRadius: CGFloat { radius * 0.86 }

	/// Lays the sublayers out for the current bounds and redraws the face at `scale`.
	func rebuild(scale: CGFloat) {
		face.frame = bounds
		backlight.frame = bounds
		face.contents = renderFace(scale: scale)
		face.contentsScale = scale
		needleGroup.frame = bounds
		needleGroup.anchorPoint = CGPoint(x: pivot.x / bounds.width, y: pivot.y / bounds.height)
		needleGroup.position = pivot
		needle.frame = bounds
		needleShadow.frame = bounds.offsetBy(dx: 0.6, dy: 1.6)
		needle.contentsScale = scale
		needleShadow.contentsScale = scale
		let tip = CGPoint(x: pivot.x, y: pivot.y - arcRadius - 9)
		let path = CGMutablePath()
		path.move(to: CGPoint(x: pivot.x - 1.4, y: pivot.y))
		path.addLine(to: CGPoint(x: tip.x - 0.45, y: tip.y))
		path.addLine(to: CGPoint(x: tip.x + 0.45, y: tip.y))
		path.addLine(to: CGPoint(x: pivot.x + 1.4, y: pivot.y))
		path.closeSubpath()
		needle.path = path
		needleShadow.path = path
		needleGroup.removeAllAnimations()
		needleGroup.setValue(Self.angle(fraction: -0.02), forKeyPath: "transform.rotation.z")
		let lampSide: CGFloat = 5
		lamp.frame = CGRect(x: bounds.width - 16, y: 10, width: lampSide, height: lampSide)
		lamp.cornerRadius = lampSide / 2
	}

	func setLive(_ value: Bool) {
		live = value
		CATransaction.begin()
		CATransaction.setAnimationDuration(1.1)
		backlight.opacity = value ? 1 : 0
		CATransaction.commit()
	}

	/// Swings the needle towards `level` with VU ballistics, and flashes the lamp on a hot peak.
	func swing(to level: Float, hot: Bool) {
		let target = Self.angle(fraction: Self.fraction(vu: Self.vu(level: level)))
		let current = (needleGroup.presentation() ?? needleGroup).value(forKeyPath: "transform.rotation.z") as? CGFloat ?? target
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		// The model takes the target too, so a drawn snapshot shows the needle where it is heading.
		needleGroup.setValue(target, forKeyPath: "transform.rotation.z")
		let turn = CABasicAnimation(keyPath: "transform.rotation.z")
		turn.fromValue = current
		turn.toValue = target
		turn.duration = 0.3
		turn.timingFunction = CAMediaTimingFunction(name: .easeOut)
		needleGroup.add(turn.cappedAtSixty(), forKey: "swing")
		if hot {
			let flash = CABasicAnimation(keyPath: "opacity")
			flash.fromValue = 1
			flash.toValue = 0.18
			flash.duration = 0.7
			flash.timingFunction = CAMediaTimingFunction(name: .easeIn)
			lamp.add(flash.cappedAtSixty(), forKey: "flash")
		}
		CATransaction.commit()
	}

	// MARK: Scale

	/// Peak sample level to VU: 0 VU at −3 dBFS; silence rests below the left stop.
	static func vu(level: Float) -> Double {
		guard level > 0 else { return -40 }
		return 20 * log10(Double(level)) + 3
	}

	/// Position along the arc, 0 at −20 and 1 at +3, a touch below zero at rest.
	static func fraction(vu: Double) -> Double {
		guard vu > anchors[0].vu else { return -0.02 }
		guard let last = anchors.last, vu < last.vu else { return 1 }
		for index in 1..<anchors.count where vu <= anchors[index].vu {
			let low = anchors[index - 1], high = anchors[index]
			let t = (vu - low.vu) / (high.vu - low.vu)
			return low.fraction + (high.fraction - low.fraction) * t
		}
		return 1
	}

	/// Needle angle for a position along the arc: 0 is straight up, positive leans right.
	static func angle(fraction: Double) -> CGFloat { CGFloat((fraction - 0.5) * span) }

	// MARK: Face

	private func point(fraction: Double, radius r: CGFloat) -> CGPoint {
		let theta = Self.angle(fraction: fraction)
		return CGPoint(x: pivot.x + sin(theta) * r, y: pivot.y - cos(theta) * r)
	}

	private func renderFace(scale: CGFloat) -> CGImage? {
		let size = bounds.size
		guard let context = CGContext(
			data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
			bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
		context.scaleBy(x: scale, y: scale)
		// Flip, so the drawing below shares the layer's top-left origin.
		context.translateBy(x: 0, y: size.height)
		context.scaleBy(x: 1, y: -1)
		let previous = NSGraphicsContext.current
		NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
		defer { NSGraphicsContext.current = previous }

		// Bezel: a dark charcoal with a hint of light at the top, like a lamp-lit panel.
		let panel = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 10, yRadius: 10)
		NSGradient(colors: [NSColor(white: 0.13, alpha: 1), NSColor(white: 0.07, alpha: 1)])?
			.draw(in: panel, angle: -90)
		NSColor(white: 1, alpha: 0.07).setStroke()
		panel.lineWidth = 1
		NSBezierPath(roundedRect: NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5), xRadius: 9.5, yRadius: 9.5).stroke()
		// A sheen across the glass.
		NSGraphicsContext.saveGraphicsState()
		panel.addClip()
		NSGradient(colors: [NSColor(white: 1, alpha: 0.09), NSColor(white: 1, alpha: 0)])?
			.draw(in: NSRect(x: 0, y: 0, width: size.width, height: size.height * 0.55), angle: -90)
		NSGraphicsContext.restoreGraphicsState()

		// The arc: white up to zero, then the red band.
		let arc = NSBezierPath()
		arc.appendArc(withCenter: pivot, radius: arcRadius,
					  startAngle: Self.degrees(fraction: 0), endAngle: Self.degrees(fraction: 0.77), clockwise: false)
		NSColor(white: 1, alpha: 0.55).setStroke()
		arc.lineWidth = 1
		arc.stroke()
		let red = NSBezierPath()
		red.appendArc(withCenter: pivot, radius: arcRadius + 1,
					  startAngle: Self.degrees(fraction: 0.77), endAngle: Self.degrees(fraction: 1), clockwise: false)
		NSColor(red: 1.0, green: 0.27, blue: 0.25, alpha: 0.95).setStroke()
		red.lineWidth = 3
		red.stroke()

		// Ticks and figures.
		let font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .semibold)
		for (index, anchor) in Self.anchors.enumerated() {
			let hot = anchor.vu >= 1
			let tick = NSBezierPath()
			tick.move(to: point(fraction: anchor.fraction, radius: arcRadius))
			tick.line(to: point(fraction: anchor.fraction, radius: arcRadius + 7))
			(hot ? NSColor(red: 1.0, green: 0.35, blue: 0.3, alpha: 1) : NSColor(white: 1, alpha: 0.8)).setStroke()
			tick.lineWidth = 1.2
			tick.stroke()
			if index + 1 < Self.anchors.count {
				let between = (anchor.fraction + Self.anchors[index + 1].fraction) / 2
				let minor = NSBezierPath()
				minor.move(to: point(fraction: between, radius: arcRadius))
				minor.line(to: point(fraction: between, radius: arcRadius + 4))
				NSColor(white: 1, alpha: 0.35).setStroke()
				minor.lineWidth = 0.8
				minor.stroke()
			}
			let label = (anchor.vu > 0 ? "+" : "") + String(Int(anchor.vu)) as NSString
			let attributes: [NSAttributedString.Key: Any] = [
				.font: font,
				.foregroundColor: hot ? NSColor(red: 1.0, green: 0.4, blue: 0.35, alpha: 1) : NSColor(white: 1, alpha: 0.82),
			]
			let textSize = label.size(withAttributes: attributes)
			let centre = point(fraction: anchor.fraction, radius: arcRadius + 15)
			label.draw(at: NSPoint(x: centre.x - textSize.width / 2, y: centre.y - textSize.height / 2), withAttributes: attributes)
		}

		// Legends.
		let vu = "VU" as NSString
		let legend: [NSAttributedString.Key: Any] = [
			.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor(white: 1, alpha: 0.7),
		]
		let vuSize = vu.size(withAttributes: legend)
		vu.draw(at: NSPoint(x: size.width / 2 - vuSize.width / 2, y: size.height * 0.66), withAttributes: legend)
		let small: [NSAttributedString.Key: Any] = [
			.font: NSFont.systemFont(ofSize: 8, weight: .semibold), .foregroundColor: NSColor(white: 1, alpha: 0.45),
		]
		(channel as NSString).draw(at: NSPoint(x: 10, y: size.height - 18), withAttributes: small)
		("PEAK" as NSString).draw(at: NSPoint(x: size.width - 44, y: 7), withAttributes: small)

		return context.makeImage()
	}

	/// `NSBezierPath` measures its angles from the x axis towards +y — downwards, in this flipped
	/// space — so straight up is −90°; the needle measures from straight up, leaning right.
	private static func degrees(fraction: Double) -> CGFloat {
		angle(fraction: fraction) * 180 / .pi - 90
	}
}

// MARK: - Pre-flight

/// One line of the pre-flight panel: what is configured, whether it looks usable, and the way to
/// go and change it.
struct PreflightRow: View {
	let symbol: String
	let label: String
	let value: String
	let ready: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			HStack(spacing: 10) {
				Image(systemName: symbol)
					.font(.system(size: 13))
					.foregroundStyle(ready ? Color.accentColor : Color.orange)
					.frame(width: 24, height: 24)
					.background(
						(ready ? Color.accentColor : Color.orange).opacity(0.12),
						in: RoundedRectangle(cornerRadius: 7, style: .continuous))
				VStack(alignment: .leading, spacing: 1) {
					Text(label)
						.font(.system(size: 12, weight: .medium))
					Text(value)
						.font(.system(size: 11))
						.foregroundStyle(ready ? .muted : Color.orange.opacity(0.9))
						.lineLimit(1)
						.truncationMode(.middle)
				}
				Spacer(minLength: 4)
				Image(systemName: "chevron.right")
					.font(.system(size: 10, weight: .semibold))
					.foregroundStyle(.faint)
			}
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}
}

// MARK: - Text tones

extension ShapeStyle where Self == Color {
	/// Secondary copy that stays legible over the window's tinted glass.
	///
	/// The system's `.secondary` and `.tertiary` label styles are calibrated for a plain grey
	/// background. Seen through a thin material over a dark, saturated field they fall well below
	/// comfortable contrast — `.tertiary` is around a quarter-opacity white in dark mode. Deriving
	/// these from the primary label keeps them correct in both schemes while raising the floor.
	static var muted: Color { Color.primary.opacity(0.68) }

	/// The quietest tone still meant to be read: units, captions, axis labels. Set where both
	/// schemes clear 4.5:1 against a card, since everything wearing it is small text.
	static var faint: Color { Color.primary.opacity(0.56) }
}
