import AVFoundation

enum AudioDevices {
	static func inputs() -> [AVCaptureDevice] {
		AVCaptureDevice.DiscoverySession(
			deviceTypes: [.microphone, .external],
			mediaType: .audio,
			position: .unspecified
		).devices
	}

	/// "Wave Link Stream" when present, otherwise the system default input.
	static func preferredInput() -> AVCaptureDevice? {
		inputs().first { $0.localizedName.localizedCaseInsensitiveContains("Wave Link Stream") }
			?? AVCaptureDevice.default(for: .audio)
	}

	static func device(uid: String) -> AVCaptureDevice? {
		inputs().first { $0.uniqueID == uid }
	}
}
