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

// MARK: - Window chrome

/// The window's translucent backing. Blurring what is behind the window is what makes a macOS
/// window sit on the desktop rather than float above it as a flat rectangle.
struct VisualEffect: NSViewRepresentable {
	var material: NSVisualEffectView.Material = .underWindowBackground

	func makeNSView(context: Context) -> NSVisualEffectView {
		let view = NSVisualEffectView()
		view.material = material
		view.blendingMode = .behindWindow
		view.state = .active
		return view
	}

	func updateNSView(_ view: NSVisualEffectView, context: Context) {
		view.material = material
	}
}

/// The window's colour field: a tinted base with three broad glows drifting across it.
///
/// One flat gradient reads as a grey wash; overlapping radial glows at different sizes give the
/// background depth, and moving them slowly keeps the window alive without asking for attention.
/// The palette turns from cool to warm the moment the stream goes out, so the window's colour says
/// what it is doing from across the room. Light and dark are separate palettes rather than one set
/// of colours at two opacities: what reads as a soft tint on white turns to mud on black.
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
			(Color(red: 0.055, green: 0.063, blue: 0.098).opacity(0.94),
			 Color(red: 0.28, green: 0.32, blue: 0.88).opacity(0.60),
			 Color(red: 0.56, green: 0.24, blue: 0.78).opacity(0.48),
			 Color(red: 0.10, green: 0.52, blue: 0.62).opacity(0.44))
		case (.dark, true):
			(Color(red: 0.095, green: 0.042, blue: 0.055).opacity(0.94),
			 Color(red: 0.88, green: 0.15, blue: 0.28).opacity(0.58),
			 Color(red: 0.96, green: 0.45, blue: 0.10).opacity(0.46),
			 Color(red: 0.54, green: 0.08, blue: 0.34).opacity(0.48))
		case (_, false):
			// Daylight: pale tints on near-white, kept weak so dark text stays comfortable.
			(Color(red: 0.965, green: 0.972, blue: 0.992).opacity(0.90),
			 Color(red: 0.40, green: 0.60, blue: 0.99).opacity(0.42),
			 Color(red: 0.72, green: 0.58, blue: 0.99).opacity(0.34),
			 Color(red: 0.40, green: 0.86, blue: 0.80).opacity(0.30))
		case (_, true):
			(Color(red: 0.996, green: 0.968, blue: 0.958).opacity(0.90),
			 Color(red: 1.00, green: 0.42, blue: 0.40).opacity(0.44),
			 Color(red: 1.00, green: 0.72, blue: 0.32).opacity(0.38),
			 Color(red: 0.98, green: 0.52, blue: 0.70).opacity(0.32))
		}
	}
}

// MARK: - Surfaces

/// A raised, translucent panel. Everything on the dashboard sits in one of these, which is what
/// gives the window a rhythm instead of a wall of controls.
struct Card<Content: View>: View {
	var padding: CGFloat = 16
	@ViewBuilder var content: Content

	private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 18, style: .continuous) }

	var body: some View {
		content
			.padding(padding)
			.frame(maxWidth: .infinity, alignment: .leading)
			// A thin material is the cheap way to look like glass: the system blurs what is behind
			// the window once, and every card samples that same blur rather than making its own.
			.background(.ultraThinMaterial, in: shape)
			.overlay {
				shape.strokeBorder(
					LinearGradient(
						colors: [Color.white.opacity(0.40), Color.white.opacity(0.05)],
						startPoint: .top, endPoint: .bottom),
					lineWidth: 1)
			}
			.shadow(color: .black.opacity(0.16), radius: 10, y: 4)
	}
}

/// The on-air badge, with a dot that breathes so the state reads from the corner of the eye.
struct LivePill: View {
	@State private var pulsing = false

	var body: some View {
		HStack(spacing: 5) {
			Circle()
				.fill(.white)
				.frame(width: 6, height: 6)
				.opacity(pulsing ? 0.35 : 1)
				.animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
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
		.onAppear { pulsing = true }
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
/// a second, and the drawing walks it from `head` rather than being handed a fresh copy.
@Observable
final class LevelTrace {
	struct Frame {
		var left: Float
		var right: Float
	}

	static let capacity = 72

	private(set) var frames = [Frame](repeating: Frame(left: 0, right: 0), count: capacity)
	private(set) var head = 0

	func push(left: Float, right: Float) {
		frames[head] = Frame(left: left, right: right)
		head = (head + 1) % Self.capacity
	}

	func clear() {
		frames = [Frame](repeating: Frame(left: 0, right: 0), count: Self.capacity)
		head = 0
	}
}

/// The one sound picture: a scrolling stereo trace with peak-hold marks.
///
/// It replaces the pair that used to sit here — a history ribbon plus a separate L/R peak meter —
/// which showed the same signal twice. Left runs above the centre line and right below it, so one
/// drawing carries the shape of the sound over time *and* which channel is doing what, and the
/// two thin marks hold the peaks, turning red at the ceiling.
struct StereoTrace: View {
	var frames: [LevelTrace.Frame]
	var head: Int
	var peakLeft: Float
	var peakRight: Float
	var live: Bool

	var body: some View {
		Canvas(rendersAsynchronously: false) { context, size in
			let count = frames.count
			guard count > 0, size.width > 0, size.height > 0 else { return }
			let middle = size.height / 2
			let step = size.width / CGFloat(count)
			let width = max(1.5, step * 0.54)
			let corner = CGSize(width: width / 2, height: width / 2)
			let shading = GraphicsContext.Shading.linearGradient(
				Gradient(colors: gradient),
				startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height))

			// Only the oldest bars fade, so those are the only ones needing their own fill; the
			// rest go into a single path and a single fill.
			let fading = Int(Double(count) * 0.3)
			var solid = Path()
			for index in 0..<count {
				let frame = frames[(head + index) % count]
				let up = CGFloat(AudioScale.fraction(frame.left)) * middle
				let down = CGFloat(AudioScale.fraction(frame.right)) * middle
				let height = max(width, up + down)
				let bar = CGRect(
					x: CGFloat(index) * step + (step - width) / 2,
					y: min(middle - up, middle - width / 2),
					width: width, height: height)
				let path = Path(roundedRect: bar, cornerSize: corner)
				if index < fading {
					context.opacity = Double(index) / Double(max(fading, 1))
					context.fill(path, with: shading)
				} else {
					solid.addPath(path)
				}
			}
			context.opacity = 1
			context.fill(solid, with: shading)

			mark(&context, y: middle - CGFloat(AudioScale.fraction(peakLeft)) * middle,
			     width: size.width, hot: peakLeft > 0.98)
			mark(&context, y: middle + CGFloat(AudioScale.fraction(peakRight)) * middle,
			     width: size.width, hot: peakRight > 0.98)
		}
	}

	private func mark(_ context: inout GraphicsContext, y: CGFloat, width: CGFloat, hot: Bool) {
		let line = Path(CGRect(x: 0, y: y - 0.5, width: width, height: 1))
		context.fill(line, with: .color(hot ? .red : Color.primary.opacity(0.35)))
	}

	private var gradient: [Color] {
		live
			? [Color.orange, Color.red, Color.orange]
			: [Color.accentColor.opacity(0.55), Color.accentColor.opacity(0.4), Color.accentColor.opacity(0.55)]
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
