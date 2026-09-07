import AppKit
import os
import ScreenCaptureKit

/// Photographs the app's own window, on request from outside.
///
/// A screenshot taken from a terminal needs the terminal to hold Screen Recording permission, which
/// is a poor thing to ask of anyone documenting a project. The app already holds that permission
/// for its screen streaming, so it takes its own picture instead. `Tools/shoot.sh` posts the
/// notification and collects the file, which is what keeps the README's images reproducible rather
/// than a set of one-off captures nobody can retake.
@MainActor
enum Screenshot {
	static let request = Notification.Name("local.microcast.shoot")
	private static let logger = Logger(subsystem: "local.microcast", category: "screenshot")

	static func listen(window: @escaping () -> NSWindow?) {
		DistributedNotificationCenter.default().addObserver(
			forName: request, object: nil, queue: .main
		) { note in
			let path = note.userInfo?["path"] as? String ?? "/tmp/microcast.png"
			// Leave a trace on arrival: without it a silent failure is indistinguishable from a
			// notification that never landed, and the tool has no log to read.
			report("received", for: path)
			MainActor.assumeIsolated {
				Task { await capture(window: window(), to: path) }
			}
		}
	}

	/// Writes progress beside the target so `shoot.sh` can report what went wrong.
	private static func report(_ message: String, for path: String) {
		try? message.write(toFile: path + ".status", atomically: true, encoding: .utf8)
	}

	private static func capture(window: NSWindow?, to path: String) async {
		guard let window, let view = window.contentView else {
			return report("no window to capture", for: path)
		}
		// Drawn from the view hierarchy rather than photographed off the screen: capturing the
		// display needs Screen Recording permission, and asking a user to hand that over just to
		// regenerate documentation images is not a reasonable trade.
		guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
			return report("could not make a bitmap for the view", for: path)
		}
		view.cacheDisplay(in: view.bounds, to: bitmap)
		guard let data = bitmap.representation(using: .png, properties: [:]) else {
			return report("could not encode the capture", for: path)
		}
		do {
			try data.write(to: URL(fileURLWithPath: path))
			report("ok", for: path)
		} catch {
			report("could not write the file: \(error.localizedDescription)", for: path)
		}
	}
}
