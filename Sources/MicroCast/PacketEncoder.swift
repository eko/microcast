import AudioToolbox
import Foundation

enum EncoderError: LocalizedError {
	case coreAudio(OSStatus, String)
	case unavailable

	var errorDescription: String? {
		switch self {
		case .coreAudio(let status, let what): "\(what) failed (OSStatus \(status))"
		case .unavailable: "encoder unavailable"
		}
	}
}

/// Encodes 48 kHz stereo 16-bit PCM into AAC or FLAC packets with the codecs built into macOS.
final class PacketEncoder {
	enum Codec {
		case aac(bitrate: Int)
		case flac
	}

	private let converter: AudioConverterRef
	private let maxPacketSize: Int
	private var pending = Data()
	private var scratch: UnsafeMutableRawPointer
	private var scratchCapacity: Int
	private var scratchLength = 0

	/// Tells the converter we are out of PCM for now; it keeps whatever it already consumed.
	private static let outOfInput: OSStatus = 0x6E6F_6D6F // 'nomo'

	init(codec: Codec) throws {
		var input = AudioStreamBasicDescription(
			mSampleRate: Double(AudioCapture.sampleRate),
			mFormatID: kAudioFormatLinearPCM,
			mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
			mBytesPerPacket: UInt32(AudioCapture.bytesPerFrame),
			mFramesPerPacket: 1,
			mBytesPerFrame: UInt32(AudioCapture.bytesPerFrame),
			mChannelsPerFrame: UInt32(AudioCapture.channels),
			mBitsPerChannel: 16,
			mReserved: 0
		)
		var output = AudioStreamBasicDescription()
		output.mSampleRate = input.mSampleRate
		output.mChannelsPerFrame = input.mChannelsPerFrame
		switch codec {
		case .aac: output.mFormatID = kAudioFormatMPEG4AAC
		case .flac: output.mFormatID = kAudioFormatFLAC
		}
		var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
		try Self.check(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &output), "describe codec")

		var created: AudioConverterRef?
		try Self.check(AudioConverterNew(&input, &output, &created), "create encoder")
		guard let created else { throw EncoderError.unavailable }
		converter = created

		if case .aac(let bitrate) = codec {
			var bitsPerSecond = UInt32(bitrate * 1000)
			try Self.check(
				AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitsPerSecond),
				"set AAC bitrate \(bitrate) kbps"
			)
		}
		var maxSize: UInt32 = 0
		size = UInt32(MemoryLayout<UInt32>.size)
		try Self.check(AudioConverterGetProperty(converter, kAudioConverterPropertyMaximumOutputPacketSize, &size, &maxSize), "read packet size")
		maxPacketSize = Int(maxSize)
		scratchCapacity = 64 * 1024
		scratch = UnsafeMutableRawPointer.allocate(byteCount: scratchCapacity, alignment: 16)
	}

	deinit {
		AudioConverterDispose(converter)
		scratch.deallocate()
	}

	/// The codec's private configuration; for FLAC it wraps the STREAMINFO block.
	var magicCookie: Data {
		var size: UInt32 = 0
		var writable: DarwinBoolean = false
		guard AudioConverterGetPropertyInfo(converter, kAudioConverterCompressionMagicCookie, &size, &writable) == noErr, size > 0 else {
			return Data()
		}
		var cookie = Data(count: Int(size))
		let status = cookie.withUnsafeMutableBytes { bytes in
			AudioConverterGetProperty(converter, kAudioConverterCompressionMagicCookie, &size, bytes.baseAddress!)
		}
		return status == noErr ? cookie : Data()
	}

	/// Feeds PCM and returns every packet the codec can complete with the audio received so far.
	func encode(_ pcm: Data) -> [Data] {
		pending.append(pcm)
		var packets: [Data] = []
		let output = UnsafeMutableRawPointer.allocate(byteCount: maxPacketSize, alignment: 16)
		defer { output.deallocate() }
		while true {
			var packetCount: UInt32 = 1
			var bufferList = AudioBufferList(
				mNumberBuffers: 1,
				mBuffers: AudioBuffer(mNumberChannels: UInt32(AudioCapture.channels), mDataByteSize: UInt32(maxPacketSize), mData: output)
			)
			var description = AudioStreamPacketDescription()
			let status = AudioConverterFillComplexBuffer(
				converter, Self.supplyInput, Unmanaged.passUnretained(self).toOpaque(), &packetCount, &bufferList, &description
			)
			if packetCount > 0 {
				let size = description.mDataByteSize > 0 ? description.mDataByteSize : bufferList.mBuffers.mDataByteSize
				packets.append(Data(bytes: output, count: Int(size)))
			}
			if status != noErr || packetCount == 0 { break }
		}
		return packets
	}

	/// Moves all pending PCM into the scratch buffer and hands it to the converter.
	private static let supplyInput: AudioConverterComplexInputDataProc = { _, packetCount, bufferList, _, context in
		let encoder = Unmanaged<PacketEncoder>.fromOpaque(context!).takeUnretainedValue()
		guard !encoder.pending.isEmpty else {
			packetCount.pointee = 0
			return PacketEncoder.outOfInput
		}
		let length = encoder.pending.count
		if length > encoder.scratchCapacity {
			encoder.scratch.deallocate()
			encoder.scratchCapacity = length * 2
			encoder.scratch = UnsafeMutableRawPointer.allocate(byteCount: encoder.scratchCapacity, alignment: 16)
		}
		encoder.pending.copyBytes(to: encoder.scratch.assumingMemoryBound(to: UInt8.self), count: length)
		encoder.pending.removeAll(keepingCapacity: true)
		encoder.scratchLength = length
		packetCount.pointee = UInt32(length / AudioCapture.bytesPerFrame)
		bufferList.pointee.mBuffers.mData = encoder.scratch
		bufferList.pointee.mBuffers.mDataByteSize = UInt32(length)
		bufferList.pointee.mBuffers.mNumberChannels = UInt32(AudioCapture.channels)
		return noErr
	}

	private static func check(_ status: OSStatus, _ what: String) throws {
		guard status == noErr else { throw EncoderError.coreAudio(status, what) }
	}
}

/// AAC packets in ADTS frames: the form `<audio>`, VLC and ffmpeg all accept as a live stream.
final class AACStream {
	let bitrate: Int
	let broadcaster = Broadcaster()
	private let encoder: PacketEncoder
	private let queue: DispatchQueue

	init(bitrate: Int) throws {
		self.bitrate = bitrate
		encoder = try PacketEncoder(codec: .aac(bitrate: bitrate))
		queue = DispatchQueue(label: "local.microcast.aac.\(bitrate)")
	}

	func append(_ pcm: Data) {
		queue.async {
			let packets = self.encoder.encode(pcm)
			guard !packets.isEmpty else { return }
			var frames = Data()
			for packet in packets {
				frames.append(ADTS.header(payloadLength: packet.count))
				frames.append(packet)
			}
			self.broadcaster.publish(frames)
		}
	}
}

enum ADTS {
	/// 7-byte header for AAC-LC, 48 kHz, stereo, no CRC.
	static func header(payloadLength: Int) -> Data {
		let length = payloadLength + 7
		return Data([
			0xFF, 0xF1,
			0x4C,
			0x80 | UInt8((length >> 11) & 0x03),
			UInt8((length >> 3) & 0xFF),
			UInt8((length & 0x07) << 5) | 0x1F,
			0xFC,
		])
	}
}

/// A raw FLAC stream: "fLaC" marker and STREAMINFO first, then the frames as the codec produces them.
final class FLACStream {
	let broadcaster = Broadcaster()
	private let encoder: PacketEncoder
	private let queue = DispatchQueue(label: "local.microcast.flac")

	init(title: String) throws {
		encoder = try PacketEncoder(codec: .flac)
		broadcaster.preamble = Self.streamHeader(cookie: encoder.magicCookie, title: title)
	}

	/// "fLaC", the STREAMINFO block (the codec cookie is a `dfLa` box whose last 34 bytes are it), then a
	/// VORBIS_COMMENT block carrying the title.
	static func streamHeader(cookie: Data, title: String) -> Data {
		var header = Data("fLaC".utf8)
		header.append(contentsOf: [0x00, 0x00, 0x00, 0x22]) // STREAMINFO, 34 bytes, more blocks follow
		if cookie.count >= 34 {
			header.append(cookie.suffix(34))
		} else {
			// block size 4608, unknown frame sizes, 48 kHz, 2 channels, 16 bits, unknown length, no MD5
			header.append(contentsOf: [0x12, 0x00, 0x12, 0x00, 0, 0, 0, 0, 0, 0, 0x0B, 0xB8, 0x02, 0xF0, 0, 0, 0, 0])
			header.append(Data(count: 16))
		}
		let vendor = Data("MicroCast".utf8)
		let comment = Data("TITLE=\(title)".utf8)
		var block = Data()
		block.append(littleEndian(UInt32(vendor.count)))
		block.append(vendor)
		block.append(littleEndian(1))
		block.append(littleEndian(UInt32(comment.count)))
		block.append(comment)
		header.append(0x84) // last metadata block, type VORBIS_COMMENT
		header.append(contentsOf: [UInt8((block.count >> 16) & 0xFF), UInt8((block.count >> 8) & 0xFF), UInt8(block.count & 0xFF)])
		header.append(block)
		return header
	}

	private static func littleEndian(_ value: UInt32) -> Data {
		Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
	}

	func append(_ pcm: Data) {
		queue.async {
			let packets = self.encoder.encode(pcm)
			guard !packets.isEmpty else { return }
			self.broadcaster.publish(packets.reduce(into: Data()) { $0.append($1) })
		}
	}
}
