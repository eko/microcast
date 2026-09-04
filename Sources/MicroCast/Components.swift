import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Stereo peak meter with a decaying peak-hold marker, dB scaled (-60 dB floor).
struct LevelMeter: View {
	var left: Float
	var right: Float
	var peakLeft: Float
	var peakRight: Float

	var body: some View {
		VStack(spacing: 4) {
			bar(level: left, peak: peakLeft, label: "L")
			bar(level: right, peak: peakRight, label: "R")
		}
	}

	private func bar(level: Float, peak: Float, label: String) -> some View {
		HStack(spacing: 6) {
			Text(label)
				.font(.system(size: 9, weight: .semibold, design: .rounded))
				.foregroundStyle(.tertiary)
				.frame(width: 8)
			GeometryReader { proxy in
				let width = proxy.size.width
				ZStack(alignment: .leading) {
					Capsule().fill(.quaternary)
					Capsule()
						.fill(LinearGradient(colors: [.green, .green, .yellow, .orange, .red], startPoint: .leading, endPoint: .trailing))
						.frame(width: width * CGFloat(Self.fraction(level)))
					Capsule()
						.fill(peak > 0.98 ? Color.red : Color.primary.opacity(0.6))
						.frame(width: 2)
						.offset(x: max(0, width * CGFloat(Self.fraction(peak)) - 1))
						.opacity(peak > 0.001 ? 1 : 0)
				}
				.mask(
					HStack(spacing: 1.5) {
						ForEach(0..<40, id: \.self) { _ in Rectangle() }
					}
				)
			}
			.frame(height: 7)
		}
	}

	static func fraction(_ level: Float) -> Float {
		guard level > 0 else { return 0 }
		let decibels = 20 * log10(level)
		return min(1, max(0, (decibels + 60) / 60))
	}
}

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
				.foregroundStyle(copied ? Color.green : Color.secondary)
				.contentTransition(.symbolEffect(.replace))
		}
		.buttonStyle(.borderless)
		.help(copied ? "Copied" : "Copy")
	}
}

enum QRCode {
	/// A black-on-white QR image for `url`, sized for the popover.
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
			.foregroundStyle(.secondary)
	}
}

enum SystemSettings {
	static func openMicrophonePrivacy() {
		if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
			NSWorkspace.shared.open(url)
		}
	}
}

/// A filled, rounded primary button drawn by SwiftUI, so it keeps its colour even when the popover is not the key window.
struct PrimaryButtonStyle: ButtonStyle {
	var color: Color

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.font(.body.weight(.semibold))
			.foregroundStyle(.white)
			.frame(maxWidth: .infinity)
			.padding(.vertical, 9)
			.background(color.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
			.contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
	}
}
