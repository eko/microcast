// Renders the MicroCast icon as an .iconset folder for iconutil.
//   swift Tools/make-icon.swift build/AppIcon.iconset
//
// The mark: five rounded waveform bars with two broadcast arcs, white on a blue gradient squircle,
// drawn on the 1024-unit Apple grid (824-unit squircle with 100-unit margins and a soft shadow).
import AppKit

let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
	NSColor(calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(pixels: Int) -> Data {
	let rep = NSBitmapImageRep(
		bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
		hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
	)!
	rep.size = NSSize(width: pixels, height: pixels)
	NSGraphicsContext.saveGraphicsState()
	let context = NSGraphicsContext(bitmapImageRep: rep)!
	NSGraphicsContext.current = context
	let u = CGFloat(pixels) / 1024 // design unit
	let cg = context.cgContext
	cg.setShouldAntialias(true)

	// Squircle background with Apple's margins and a drop shadow (skipped at tiny sizes where it only blurs).
	let square = NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
	let shape = NSBezierPath(roundedRect: square, xRadius: 186 * u, yRadius: 186 * u)
	if pixels >= 64 {
		cg.saveGState()
		cg.setShadow(offset: CGSize(width: 0, height: -14 * u), blur: 30 * u, color: NSColor.black.withAlphaComponent(0.28).cgColor)
		color(0x2B5BD7).setFill()
		shape.fill()
		cg.restoreGState()
	}
	NSGradient(colorsAndLocations: (color(0x5F9BFF), 0), (color(0x2F6DF6), 0.55), (color(0x1B3A9C), 1))!
		.draw(in: shape, angle: -62)
	// Soft highlight in the top-left, a hint of depth without gloss.
	cg.saveGState()
	shape.addClip()
	NSGradient(colorsAndLocations: (NSColor.white.withAlphaComponent(0.22), 0), (NSColor.white.withAlphaComponent(0), 1))!
		.draw(fromCenter: NSPoint(x: 320 * u, y: 780 * u), radius: 0, toCenter: NSPoint(x: 320 * u, y: 780 * u), radius: 620 * u, options: [])
	cg.restoreGState()

	// Glyph shadow: subtle, so the white keeps contrast on the light top edge.
	cg.saveGState()
	if pixels >= 64 {
		cg.setShadow(offset: CGSize(width: 0, height: -8 * u), blur: 16 * u, color: NSColor.black.withAlphaComponent(0.22).cgColor)
	}
	NSColor.white.setFill()
	NSColor.white.setStroke()

	// Waveform: five bars, slightly left of centre to leave room for the arcs, heights forming a soft peak.
	let barWidth = 80 * u
	let gap = 42 * u
	let heights: [CGFloat] = [220, 372, 520, 372, 220]
	let totalWidth = barWidth * 5 + gap * 4
	let startX = (1024 * u - totalWidth) / 2 - 30 * u
	let centerY = 500 * u
	var x = startX
	for height in heights {
		let bar = NSRect(x: x, y: centerY - height * u / 2, width: barWidth, height: height * u)
		NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
		x += barWidth + gap
	}

	// Two broadcast arcs from the top-right of the waveform, kept inside the squircle.
	if pixels >= 32 {
		let origin = NSPoint(x: startX + totalWidth + 6 * u, y: centerY + 100 * u)
		for radius in [74.0, 138.0] {
			let arc = NSBezierPath()
			arc.lineWidth = 40 * u
			arc.lineCapStyle = .round
			arc.appendArc(withCenter: origin, radius: CGFloat(radius) * u, startAngle: -6, endAngle: 96)
			arc.stroke()
		}
	}
	cg.restoreGState()

	NSGraphicsContext.restoreGraphicsState()
	return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
	try render(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
	try render(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
