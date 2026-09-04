import CoreGraphics
import Foundation

/// A rectangle of a display to capture, in points, top-left origin (as ScreenCaptureKit's sourceRect wants).
struct ScreenRegion: Equatable {
	var x: Int
	var y: Int
	var width: Int
	var height: Int

	var isEmpty: Bool { width <= 0 || height <= 0 }
	var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

	/// Clamps the region to a display of `size` points, keeping at least a small area on screen.
	func clamped(to size: CGSize) -> ScreenRegion {
		let displayWidth = Int(size.width.rounded())
		let displayHeight = Int(size.height.rounded())
		let w = max(16, min(width, displayWidth))
		let h = max(16, min(height, displayHeight))
		return ScreenRegion(
			x: max(0, min(x, displayWidth - w)),
			y: max(0, min(y, displayHeight - h)),
			width: w,
			height: h
		)
	}

	/// The output pixel size for a region rendered at `scale`, capped so the long edge is at most `maxWidth`.
	func outputSize(scale: CGFloat, maxWidth: Int) -> (width: Int, height: Int) {
		let pixelWidth = CGFloat(width) * scale
		let pixelHeight = CGFloat(height) * scale
		guard pixelWidth > CGFloat(maxWidth) else {
			return (max(2, Int(pixelWidth.rounded())), max(2, Int(pixelHeight.rounded())))
		}
		let ratio = CGFloat(maxWidth) / pixelWidth
		// even dimensions keep JPEG/encoders happy
		let width = (Int((pixelWidth * ratio).rounded()) / 2) * 2
		let height = (Int((pixelHeight * ratio).rounded()) / 2) * 2
		return (max(2, width), max(2, height))
	}
}

/// Frames the JPEG stream as `multipart/x-mixed-replace`, which browsers play in a plain `<img>`.
enum MJPEG {
	static let boundary = "microcastframe"
	static let contentType = "multipart/x-mixed-replace; boundary=\(boundary)"

	/// One part: boundary, headers, the JPEG, trailing CRLF.
	static func part(_ jpeg: Data) -> Data {
		var data = Data("--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
		data.append(jpeg)
		data.append(Data("\r\n".utf8))
		return data
	}
}
