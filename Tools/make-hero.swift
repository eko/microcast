// Composes the README's hero image from real screenshots.
//   swift Tools/make-hero.swift docs/images/hero.png
//
// The screenshots come from Tools/shoot.sh, so the picture at the top of the README can be
// regenerated after a redesign instead of slowly drifting away from the app it advertises.
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/images/hero.png")
let shots = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "docs/images"

let width: CGFloat = 2000
let height: CGFloat = 1200

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
	NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
	        blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
	NSFont.systemFont(ofSize: size, weight: weight)
}

func draw(_ text: String, at point: NSPoint, _ f: NSFont, _ c: NSColor, tracking: CGFloat = 0) {
	var attributes: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: c]
	if tracking != 0 { attributes[.kern] = tracking }
	text.draw(at: point, withAttributes: attributes)
}

/// Wraps a paragraph inside a fixed width, returning the height it took.
@discardableResult
func draw(paragraph: String, in rect: NSRect, _ f: NSFont, _ c: NSColor) -> CGFloat {
	let style = NSMutableParagraphStyle()
	style.lineSpacing = 10
	let attributed = NSAttributedString(string: paragraph, attributes: [
		.font: f, .foregroundColor: c, .paragraphStyle: style,
	])
	attributed.draw(with: rect, options: [.usesLineFragmentOrigin])
	return attributed.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin]).height
}

/// A screenshot, rounded and lifted off the background.
func plate(_ image: NSImage, at origin: NSPoint, height plateHeight: CGFloat, radius: CGFloat = 26,
           shadow: CGFloat = 60, alpha: CGFloat = 1, trimBottom: CGFloat = 0) {
	// A window taller than its content leaves a strip of empty background at the foot of the
	// screenshot; trimming it keeps the plate looking like a window rather than a tall crop.
	let source = NSRect(x: 0, y: image.size.height * trimBottom,
	                    width: image.size.width, height: image.size.height * (1 - trimBottom))
	let scale = plateHeight / source.height
	let rect = NSRect(x: origin.x, y: origin.y, width: source.width * scale, height: plateHeight)
	NSGraphicsContext.saveGraphicsState()
	let drop = NSShadow()
	drop.shadowColor = color(0x000000, 0.55)
	drop.shadowBlurRadius = shadow
	drop.shadowOffset = NSSize(width: 0, height: -18)
	drop.set()
	let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
	color(0x000000).setFill()
	path.fill()
	NSGraphicsContext.restoreGraphicsState()

	NSGraphicsContext.saveGraphicsState()
	path.addClip()
	image.draw(in: rect, from: source, operation: .sourceOver, fraction: alpha)
	NSGraphicsContext.restoreGraphicsState()

	color(0xffffff, 0.10).setStroke()
	path.lineWidth = 2
	path.stroke()
}

func pill(_ text: String, at origin: NSPoint, accent: String? = nil) -> CGFloat {
	let body = font(26, .medium)
	let strong = font(26, .semibold)
	let accentWidth = accent.map { ($0 as NSString).size(withAttributes: [.font: strong]).width + 10 } ?? 0
	let textWidth = (text as NSString).size(withAttributes: [.font: body]).width
	let rect = NSRect(x: origin.x, y: origin.y, width: accentWidth + textWidth + 56, height: 64)
	let path = NSBezierPath(roundedRect: rect, xRadius: 32, yRadius: 32)
	color(0xffffff, 0.05).setFill()
	path.fill()
	color(0xffffff, 0.14).setStroke()
	path.lineWidth = 2
	path.stroke()
	var x = rect.minX + 28
	if let accent {
		draw(accent, at: NSPoint(x: x, y: rect.minY + 17), strong, color(0x4d8dff))
		x += accentWidth
	}
	draw(text, at: NSPoint(x: x, y: rect.minY + 17), body, color(0xffffff, 0.88))
	return rect.width + 18
}

// MARK: - Canvas

let bitmap = NSBitmapImageRep(
	bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
	bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
	colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

// Ground: a near-black field with a cool wash in one corner and a warm one where the on-air
// window sits, echoing the app's own two palettes.
color(0x07080d).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()
NSGradient(colors: [color(0x1b2a6b, 0.55), color(0x07080d, 0)])!
	.draw(in: NSRect(x: -300, y: 300, width: 1500, height: 1500), relativeCenterPosition: .zero)
NSGradient(colors: [color(0x7a1f2e, 0.42), color(0x07080d, 0)])!
	.draw(in: NSRect(x: 900, y: -200, width: 1500, height: 1500), relativeCenterPosition: .zero)

// A faint grid, so the flat ground has some structure without competing with the screenshots.
color(0xffffff, 0.030).setStroke()
let grid = NSBezierPath()
grid.lineWidth = 1
for x in stride(from: CGFloat(0), through: width, by: 50) {
	grid.move(to: NSPoint(x: x, y: 0)); grid.line(to: NSPoint(x: x, y: height))
}
for y in stride(from: CGFloat(0), through: height, by: 50) {
	grid.move(to: NSPoint(x: 0, y: y)); grid.line(to: NSPoint(x: width, y: y))
}
grid.stroke()

// MARK: - Screenshots

func load(_ name: String) -> NSImage? { NSImage(contentsOfFile: "\(shots)/\(name)") }

// The listener's page sits behind and above, the app in front: the two halves of the product.
if let page = load("page-dark.png") {
	plate(page, at: NSPoint(x: 1492, y: 232), height: 900, radius: 22, shadow: 70, alpha: 0.90)
}
if let app = load("onair.png") {
	plate(app, at: NSPoint(x: 986, y: 74), height: 1052, radius: 30, shadow: 100, trimBottom: 0.055)
}

// MARK: - Words

if let icon = NSImage(contentsOfFile: "\(shots)/icon.png") {
	icon.draw(in: NSRect(x: 120, y: 852, width: 168, height: 168))
}

draw("MicroCast", at: NSPoint(x: 116, y: 690), font(108, .bold), .white, tracking: -2)
draw("Your Mac, live on the air.", at: NSPoint(x: 120, y: 610), font(42, .medium), color(0xffffff, 0.82))
draw(paragraph:
	"Capture any input or the apps themselves and put it on the air: low-latency HLS, AAC, MP3, "
		+ "FLAC and raw PCM, from the menu bar, on your network or on your own domain with HTTPS.",
	in: NSRect(x: 120, y: 380, width: 760, height: 200), font(27, .regular), color(0xffffff, 0.62))

var x: CGFloat = 120
x += pill("Low-Latency HLS", at: NSPoint(x: x, y: 268), accent: "1 s")
x += pill("ultra-low latency", at: NSPoint(x: x, y: 268), accent: "0.2 s")
x = 120
x += pill("AAC · MP3 · FLAC · PCM", at: NSPoint(x: x, y: 186))
x += pill("Jingles · Now Playing", at: NSPoint(x: x, y: 186))
x = 120
_ = pill("Cloudflare · ngrok · DuckDNS · HTTPS", at: NSPoint(x: x, y: 104))

draw("macOS 14.2+  ·  open source  ·  MIT", at: NSPoint(x: 120, y: 40), font(24, .regular), color(0xffffff, 0.34))

NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else {
	FileHandle.standardError.write(Data("could not encode the hero\n".utf8))
	exit(1)
}
try data.write(to: output)
print("wrote \(output.path)  \(Int(width))×\(Int(height))")
