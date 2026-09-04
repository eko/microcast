import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import CoreMedia
import os

/// Something that feeds the pipeline: 48 kHz stereo 16-bit buffers plus a level reading.
protocol AudioSource: AnyObject {
	var levels: (left: Float, right: Float) { get }
	func start()
	func stop()
}

extension AudioCapture: AudioSource {}

enum TapError: LocalizedError {
	case coreAudio(OSStatus, String)
	case noSelection
	case unsupportedFormat

	var errorDescription: String? {
		switch self {
		case .coreAudio(let status, let what): "\(what) failed (OSStatus \(status))"
		case .noSelection: "none of the selected applications is running"
		case .unsupportedFormat: "unexpected tap audio format"
		}
	}
}

// MARK: - Running applications with audio

/// A running app that has an audio session, with the helper processes it is responsible for
/// (Safari's WebKit helpers, Chrome's utility processes…).
struct AudioApp: Identifiable, Hashable {
	let pid: pid_t
	let name: String
	let bundleID: String?
	let isPlaying: Bool
	let processObjects: [AudioObjectID]

	var id: String { bundleID ?? "pid-\(pid)" }

	private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
	private static let responsibleFunction: ResponsibleFunction? = {
		guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
		return unsafeBitCast(symbol, to: ResponsibleFunction.self)
	}()

	/// Apps visible in the Dock or menu bar, plus anything currently playing; sorted playing first.
	static func running() -> [AudioApp] {
		var groups: [pid_t: (name: String, bundleID: String?, playing: Bool, objects: [AudioObjectID])] = [:]
		for objectID in (try? CoreAudioProperty.objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)) ?? [] {
			var pid: pid_t = 0
			guard (try? CoreAudioProperty.read(objectID, kAudioProcessPropertyPID, into: &pid)) != nil, pid > 0 else { continue }
			var playing: UInt32 = 0
			try? CoreAudioProperty.read(objectID, kAudioProcessPropertyIsRunningOutput, into: &playing)
			let owner = responsibleFunction.map { $0(pid) }.flatMap { $0 > 0 ? $0 : nil } ?? pid
			let app = NSRunningApplication(processIdentifier: owner)
			var group = groups[owner] ?? (app?.localizedName ?? processName(owner), app?.bundleIdentifier, false, [])
			group.playing = group.playing || playing != 0
			group.objects.append(objectID)
			groups[owner] = group
		}
		return groups.compactMap { pid, group in
			let visible = NSRunningApplication(processIdentifier: pid).map { $0.activationPolicy != .prohibited } ?? false
			guard visible || group.playing, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
			return AudioApp(pid: pid, name: group.name, bundleID: group.bundleID, isPlaying: group.playing, processObjects: group.objects)
		}
		.sorted { lhs, rhs in
			if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
			return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
		}
	}

	private static func processName(_ pid: pid_t) -> String {
		var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
		return proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : "pid \(pid)"
	}
}

// MARK: - Permission ("System Audio Recording Only")

/// Process taps deliver silence without this permission and never prompt by themselves; there is no public
/// API to ask, so this uses the TCC entry points AudioCap relies on, and degrades to "just try" if they vanish.
enum SystemAudioPermission {
	enum Status { case granted, denied, unknown, unavailable }

	private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
	private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
	private static let service = "kTCCServiceAudioCapture" as CFString
	private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

	static var status: Status {
		guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return .unavailable }
		switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
		case 0: return .granted
		case 1: return .denied
		default: return .unknown
		}
	}

	/// Prompts if macOS has never asked. Returns false only on an explicit denial.
	static func request() async -> Bool {
		switch status {
		case .granted, .unavailable: return true
		case .denied: return false
		case .unknown: break
		}
		guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else { return true }
		let request = unsafeBitCast(symbol, to: Request.self)
		return await withCheckedContinuation { continuation in
			request(service, nil) { granted in continuation.resume(returning: granted) }
		}
	}

	static func openSettings() {
		if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
			NSWorkspace.shared.open(url)
		}
	}
}

// MARK: - Core Audio helpers

enum CoreAudioProperty {
	static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
		AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
	}

	static func check(_ status: OSStatus, _ what: String) throws {
		guard status == noErr else { throw TapError.coreAudio(status, what) }
	}

	static func read<T: BitwiseCopyable>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, into value: inout T) throws {
		var address = address(selector, scope: scope)
		var size = UInt32(MemoryLayout<T>.size)
		try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value), "read property")
	}

	static func readString(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
		var value: CFString = "" as CFString
		var address = address(selector)
		var size = UInt32(MemoryLayout<CFString>.size)
		try withUnsafeMutablePointer(to: &value) { pointer in
			try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer), "read string property")
		}
		return value as String
	}

	static func objectList(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
		var address = address(selector)
		var size: UInt32 = 0
		try check(AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size), "size of list")
		var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
		try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &list), "read list")
		return list
	}

	static func deviceID(uid: String) throws -> AudioObjectID? {
		for device in try objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
		where (try? readString(device, kAudioDevicePropertyDeviceUID)) == uid {
			return device
		}
		return nil
	}

	/// Number of input channels a device exposes, summed over its input streams.
	static func inputChannels(of device: AudioObjectID) throws -> Int {
		var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
		var size: UInt32 = 0
		try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "stream configuration size")
		let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
		defer { raw.deallocate() }
		try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw), "stream configuration")
		let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
		return list.reduce(0) { $0 + Int($1.mNumberChannels) }
	}
}

// MARK: - Tap capture

/// Captures the output of chosen applications (or of everything) through a Core Audio process tap, optionally
/// mixed with an input device, and delivers 48 kHz stereo 16-bit buffers like `AudioCapture` does.
final class TapCapture: AudioSource {
	enum Target {
		case apps([AudioApp])
		case all
	}

	private var tapID = AudioObjectID(kAudioObjectUnknown)
	private var aggregateID = AudioObjectID(kAudioObjectUnknown)
	private var procID: AudioDeviceIOProcID?
	private let queue = DispatchQueue(label: "local.microcast.tap", qos: .userInteractive)
	private let sink: (Data) -> Void
	private let peakLevels = OSAllocatedUnfairLock(initialState: (left: Float(0), right: Float(0)))
	private let logger = Logger(subsystem: "local.microcast", category: "tap")

	private var inputChannels = 0
	private var deviceRate: Double = 48_000
	private var converter: AVAudioConverter?
	private var sourceFormat: AVAudioFormat?
	private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(AudioCapture.sampleRate), channels: 2, interleaved: true)!

	var levels: (left: Float, right: Float) { peakLevels.withLock { $0 } }

	init(target: Target, mixInputDeviceUID: String?, sink: @escaping (Data) -> Void) throws {
		self.sink = sink
		let description: CATapDescription
		switch target {
		case .apps(let apps):
			let objects = apps.flatMap(\.processObjects)
			guard !objects.isEmpty else { throw TapError.noSelection }
			description = CATapDescription(stereoMixdownOfProcesses: objects)
		case .all:
			description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
		}
		description.uuid = UUID()
		description.muteBehavior = .unmuted
		description.name = "MicroCast"
		try CoreAudioProperty.check(AudioHardwareCreateProcessTap(description, &tapID), "create process tap")

		// The tap needs a device to clock against: the input we mix in, or else the system output.
		var clockDevice = AudioObjectID(kAudioObjectUnknown)
		if let mixInputDeviceUID, let device = try CoreAudioProperty.deviceID(uid: mixInputDeviceUID) {
			clockDevice = device
			inputChannels = try CoreAudioProperty.inputChannels(of: device)
		} else {
			try CoreAudioProperty.read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, into: &clockDevice)
		}
		let clockUID = try CoreAudioProperty.readString(clockDevice, kAudioDevicePropertyDeviceUID)
		let aggregate: [String: Any] = [
			kAudioAggregateDeviceNameKey: "MicroCast",
			kAudioAggregateDeviceUIDKey: "local.microcast.aggregate.\(UUID().uuidString)",
			kAudioAggregateDeviceMainSubDeviceKey: clockUID,
			kAudioAggregateDeviceIsPrivateKey: true,
			kAudioAggregateDeviceIsStackedKey: false,
			kAudioAggregateDeviceTapAutoStartKey: true,
			kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockUID]],
			kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
		]
		try CoreAudioProperty.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate device")

		try CoreAudioProperty.read(aggregateID, kAudioDevicePropertyNominalSampleRate, into: &deviceRate)
		guard let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: deviceRate, channels: 2) else { throw TapError.unsupportedFormat }
		self.sourceFormat = sourceFormat
		converter = AVAudioConverter(from: sourceFormat, to: outputFormat)
		try CoreAudioProperty.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
			self?.process(input)
		}, "create IO proc")
		logger.info("tap ready: \(self.deviceRate) Hz, \(self.inputChannels) input channels mixed in")
	}

	deinit {
		stop()
		if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
		if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
	}

	func start() {
		guard let procID else { return }
		let status = AudioDeviceStart(aggregateID, procID)
		if status != noErr { logger.error("AudioDeviceStart failed: \(status)") }
	}

	func stop() {
		guard let procID else { return }
		AudioDeviceStop(aggregateID, procID)
		AudioDeviceDestroyIOProcID(aggregateID, procID)
		self.procID = nil
	}

	/// Flattens the aggregate's input buffers into channels (input device first, tap last), mixes to stereo,
	/// resamples to 48 kHz Int16 and hands the result to the sink.
	private func process(_ list: UnsafePointer<AudioBufferList>) {
		let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
		var channels: [UnsafeMutablePointer<Float>] = []
		var frames = 0
		var scratch: [[Float]] = []
		for buffer in buffers {
			guard let data = buffer.mData else { continue }
			let count = Int(buffer.mNumberChannels)
			let samples = data.assumingMemoryBound(to: Float.self)
			let bufferFrames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / max(1, count)
			frames = frames == 0 ? bufferFrames : min(frames, bufferFrames)
			if count == 1 {
				channels.append(samples)
			} else {
				for channel in 0..<count {
					var plane = [Float](repeating: 0, count: bufferFrames)
					for frame in 0..<bufferFrames { plane[frame] = samples[frame * count + channel] }
					scratch.append(plane)
				}
			}
		}
		// Planar copies must outlive the mix; keep them addressable here.
		scratch.withUnsafeMutableBufferPointer { planes in
			for index in planes.indices { planes[index].withUnsafeMutableBufferPointer { channels.append($0.baseAddress!) } }
			guard frames > 0, channels.count >= 2, let sourceFormat, let converter,
				let mixed = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
			mixed.frameLength = AVAudioFrameCount(frames)
			let tapLeft = channels[channels.count - 2], tapRight = channels[channels.count - 1]
			let inputLeft = inputChannels >= 1 ? channels[0] : nil
			let inputRight = inputChannels >= 2 ? channels[1] : inputLeft
			let outLeft = mixed.floatChannelData![0], outRight = mixed.floatChannelData![1]
			for frame in 0..<frames {
				outLeft[frame] = max(-1, min(1, tapLeft[frame] + (inputLeft?[frame] ?? 0)))
				outRight[frame] = max(-1, min(1, tapRight[frame] + (inputRight?[frame] ?? 0)))
			}
			deliver(mixed, converter: converter)
		}
	}

	private func deliver(_ mixed: AVAudioPCMBuffer, converter: AVAudioConverter) {
		let capacity = AVAudioFrameCount(Double(mixed.frameLength) * outputFormat.sampleRate / deviceRate) + 32
		guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
		var consumed = false
		var error: NSError?
		converter.convert(to: output, error: &error) { _, status in
			if consumed { status.pointee = .noDataNow; return nil }
			consumed = true
			status.pointee = .haveData
			return mixed
		}
		guard error == nil, output.frameLength > 0 else { return }
		let frames = Int(output.frameLength)
		let pcm = Data(bytes: output.int16ChannelData![0], count: frames * AudioCapture.bytesPerFrame)
		peakLevels.withLock { $0 = AudioCapture.peaks(of: pcm) }
		sink(pcm)
	}
}
