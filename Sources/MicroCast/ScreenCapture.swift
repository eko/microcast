import AppKit
import CoreImage
import Foundation
import os
import ScreenCaptureKit

/// A source of MJPEG screen frames the router can serve.
protocol ScreenSource: AnyObject {
	var broadcaster: Broadcaster { get }
	func latestFrame() -> Data?
}

/// Screen Recording permission via the public CoreGraphics calls (no private TCC needed).
enum ScreenPermission {
	static var granted: Bool { CGPreflightScreenCaptureAccess() }

	/// Prompts the first time; returns false on an explicit denial. Never blocks.
	@discardableResult
	static func request() -> Bool { CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() }

	static func openSettings() {
		if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
			NSWorkspace.shared.open(url)
		}
	}
}

struct ScreenDisplay: Identifiable, Hashable {
	let id: CGDirectDisplayID
	let name: String
	let width: Int
	let height: Int
}

/// Captures a region of a display with ScreenCaptureKit and publishes JPEG frames as MJPEG parts.
final class ScreenCapture: NSObject, ScreenSource, SCStreamOutput {
	let broadcaster = Broadcaster()

	private let displayID: CGDirectDisplayID
	private let region: ScreenRegion
	private let fps: Int
	private let maxWidth: Int
	private let quality: Double
	private var stream: SCStream?
	private let context = CIContext(options: [.useSoftwareRenderer: false])
	private let queue = DispatchQueue(label: "local.microcast.screen", qos: .userInitiated)
	private let latest = OSAllocatedUnfairLock<Data?>(initialState: nil)
	private let logger = Logger(subsystem: "local.microcast", category: "screen")

	init(displayID: CGDirectDisplayID, region: ScreenRegion, fps: Int, maxWidth: Int, quality: Double) {
		self.displayID = displayID
		self.region = region
		self.fps = max(1, min(30, fps))
		self.maxWidth = max(160, maxWidth)
		self.quality = min(1, max(0.2, quality))
	}

	func latestFrame() -> Data? { latest.withLock { $0 } }

	/// Lists the displays that can be captured (needs Screen Recording permission).
	static func displays() async -> [ScreenDisplay] {
		guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return [] }
		return content.displays.map { display in
			let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID }
			return ScreenDisplay(id: display.displayID, name: screen?.localizedName ?? "Display \(display.displayID)", width: display.width, height: display.height)
		}
	}

	func start() async throws {
		let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
		guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
			throw NSError(domain: "microcast.screen", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display to capture"])
		}
		let bounds = ScreenRegion(x: 0, y: 0, width: display.width, height: display.height)
		let clamped = region.isEmpty ? bounds : region.clamped(to: CGSize(width: display.width, height: display.height))
		let scale = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID }?.backingScaleFactor ?? 2
		let output = clamped.outputSize(scale: scale, maxWidth: maxWidth)

		let configuration = SCStreamConfiguration()
		configuration.sourceRect = clamped.cgRect
		configuration.width = output.width
		configuration.height = output.height
		configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
		configuration.showsCursor = true
		configuration.pixelFormat = kCVPixelFormatType_32BGRA
		configuration.queueDepth = 4
		configuration.scalesToFit = true

		let filter = SCContentFilter(display: display, excludingWindows: [])
		let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
		try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
		try await stream.startCapture()
		self.stream = stream
		logger.info("screen capture \(output.width)x\(output.height) @ \(self.fps) fps")
	}

	func stop() {
		stream?.stopCapture { _ in }
		stream = nil
		broadcaster.closeAll()
	}

	func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
		guard type == .screen, sampleBuffer.isValid, let imageBuffer = sampleBuffer.imageBuffer else { return }
		// SCStreamFrameInfo.status: skip idle/blank frames the compositor emits when nothing changed.
		if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
			let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw), status != .complete {
			return
		}
		let image = CIImage(cvImageBuffer: imageBuffer)
		guard let jpeg = context.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]) else { return }
		latest.withLock { $0 = jpeg }
		broadcaster.publish(MJPEG.part(jpeg))
	}
}


/// A synthetic screen source (animated JPEG) for screenshots and tests without Screen Recording permission.
final class DemoScreenSource: ScreenSource {
	let broadcaster = Broadcaster()
	private var timer: Timer?
	private let latest = OSAllocatedUnfairLock<Data?>(initialState: nil)
	private var tick = 0

	func latestFrame() -> Data? { latest.withLock { $0 } }

	func start() {
		let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.render() }
		RunLoop.main.add(timer, forMode: .common)
		self.timer = timer
		render()
	}

	func stop() { timer?.invalidate(); timer = nil; broadcaster.closeAll() }

	private func render() {
		tick += 1
		let width = 960, height = 540
		guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
		context.setFillColor(CGColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
		let hue = CGFloat(tick % 100) / 100
		context.setFillColor(NSColor(hue: hue, saturation: 0.7, brightness: 0.9, alpha: 1).cgColor)
		context.fillEllipse(in: CGRect(x: CGFloat((tick * 12) % (width - 160)), y: 190, width: 160, height: 160))
		guard let image = context.makeImage() else { return }
		let rep = NSBitmapImageRep(cgImage: image)
		guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return }
		latest.withLock { $0 = jpeg }
		broadcaster.publish(MJPEG.part(jpeg))
	}
}
