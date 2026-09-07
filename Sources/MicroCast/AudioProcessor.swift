import Foundation

/// Broadcast-style loudness processing: input gain → stereo-linked compressor → look-ahead limiter.
/// A raw capture typically sits 10-15 dB below a radio station; this chain closes that gap without clipping.
struct AudioProcessor {
	enum Preset: String, CaseIterable, Identifiable {
		case off, limiter, light, broadcast, loud

		var id: String { rawValue }

		var label: String {
			switch self {
			case .off: "Off (raw capture)"
			case .limiter: "Safety limiter only"
			case .light: "Light — gentle levelling"
			case .broadcast: "Broadcast — like a radio station"
			case .loud: "Loud — maximum punch"
			}
		}

		/// Roughly the integrated loudness each preset aims for on typical music.
		var summary: String {
			switch self {
			case .off: "No processing; the stream is as loud as the source, and can clip if the source is hot."
			case .limiter: "Leaves your sound untouched but stops it exceeding full scale, which avoids encoder distortion."
			case .light: "About 4 dB louder, keeps most of the dynamics."
			case .broadcast: "About 10 dB louder and steady, close to FM radio."
			case .loud: "Loudest and most compressed, for noisy environments."
			}
		}

		var parameters: AudioProcessor.Parameters? {
			switch self {
			case .off: nil
			case .limiter: .init(targetRMSDB: nil, inputGainDB: 0, thresholdDB: 0, ratio: 1.01, attackMs: 5, releaseMs: 100, makeupDB: 0)
			case .light: .init(targetRMSDB: -21, inputGainDB: 0, thresholdDB: -14, ratio: 2, attackMs: 15, releaseMs: 250, makeupDB: 4)
			case .broadcast: .init(targetRMSDB: -16, inputGainDB: 0, thresholdDB: -12, ratio: 4, attackMs: 6, releaseMs: 140, makeupDB: 8)
			case .loud: .init(targetRMSDB: -13, inputGainDB: 0, thresholdDB: -10, ratio: 6, attackMs: 3, releaseMs: 90, makeupDB: 9)
			}
		}
	}

	struct Parameters {
		/// Level the slow gain stage aims for, so the result is the same whether the source is quiet or hot.
		/// nil means no automatic gain (the safety limiter).
		var targetRMSDB: Float?
		var inputGainDB: Float
		var thresholdDB: Float
		var ratio: Float
		var attackMs: Float
		var releaseMs: Float
		var makeupDB: Float
		/// Sample ceiling, ~2 dB below full scale. A sample-domain limiter still lets inter-sample peaks through
		/// and the MP3/AAC encoders overshoot by roughly 1.5 dB, so this keeps the encoded true peak negative.
		var ceiling: Float = 0.79
	}

	static let lookaheadFrames = 240 // 5 ms at 48 kHz

	private var parameters: Parameters?
	private var envelope: Float = 0
	private var attackCoefficient: Float = 0
	private var releaseCoefficient: Float = 0
	private var limiterGain: Float = 1
	private var meanSquare: Float = 0
	private var automaticGain: Float = 1
	private var delayLeft = [Float](repeating: 0, count: AudioProcessor.lookaheadFrames)
	private var delayRight = [Float](repeating: 0, count: AudioProcessor.lookaheadFrames)
	private var delayIndex = 0

	init(preset: Preset = .off) {
		setPreset(preset)
	}

	var isActive: Bool { parameters != nil }

	mutating func setPreset(_ preset: Preset) {
		let new = preset.parameters
		// Keep the running state when the parameters are unchanged so live edits don't click.
		if new == nil { parameters = nil; return }
		parameters = new
		let rate: Float = Float(AudioCapture.sampleRate)
		attackCoefficient = 1 - exp(-1 / (max(0.1, new!.attackMs) * 0.001 * rate))
		releaseCoefficient = 1 - exp(-1 / (max(1, new!.releaseMs) * 0.001 * rate))
	}

	/// Processes interleaved stereo 16-bit samples in place.
	mutating func process(_ samples: UnsafeMutableBufferPointer<Int16>) {
		guard let parameters else { return }
		let inputGain = pow(10, parameters.inputGainDB / 20)
		let makeup = pow(10, parameters.makeupDB / 20)
		let threshold = pow(10, parameters.thresholdDB / 20)
		let ceiling = parameters.ceiling
		let slope = 1 - 1 / max(1.01, parameters.ratio)
		let limiterRelease: Float = 1 - exp(-1 / (0.05 * Float(AudioCapture.sampleRate)))

		// Slow leveller: ~1.5 s so it rides the programme level without pumping.
		let agcCoefficient: Float = 1 - exp(-1 / (1.5 * Float(AudioCapture.sampleRate)))
		let target = parameters.targetRMSDB.map { pow(10, $0 / 20) }
		let maximumBoost: Float = 12, maximumCut: Float = 0.5, gate: Float = 0.0003 // ~ -70 dBFS

		var index = 0
		while index + 1 < samples.count {
			var left = Float(samples[index]) / 32_768 * inputGain
			var right = Float(samples[index + 1]) / 32_768 * inputGain

			if let target {
				let instant = max(abs(left), abs(right))
				meanSquare += (instant * instant - meanSquare) * agcCoefficient
				let rms = sqrt(meanSquare)
				if rms > gate {
					let wanted = min(maximumBoost, max(maximumCut, target / rms))
					automaticGain += (wanted - automaticGain) * agcCoefficient
				}
				left *= automaticGain
				right *= automaticGain
			}

			// Stereo-linked envelope follower on the peak of both channels.
			let level = max(abs(left), abs(right))
			envelope += (level - envelope) * (level > envelope ? attackCoefficient : releaseCoefficient)

			// Compressor: reduce everything above the threshold by the ratio.
			if envelope > threshold {
				let overDecibels = 20 * log10(max(envelope, 1e-6) / threshold)
				let gain = pow(10, -(overDecibels * slope) / 20)
				left *= gain
				right *= gain
			}
			left *= makeup
			right *= makeup

			// Look-ahead limiter: the gain drops before the peak reaches the output.
			let peak = max(abs(left), abs(right))
			if peak > ceiling {
				limiterGain = min(limiterGain, ceiling / peak)
			} else {
				limiterGain += (1 - limiterGain) * limiterRelease
			}
			let delayedLeft = delayLeft[delayIndex]
			let delayedRight = delayRight[delayIndex]
			delayLeft[delayIndex] = left
			delayRight[delayIndex] = right
			delayIndex = (delayIndex + 1) % Self.lookaheadFrames

			samples[index] = Self.clamp(delayedLeft * limiterGain, ceiling: ceiling)
			samples[index + 1] = Self.clamp(delayedRight * limiterGain, ceiling: ceiling)
			index += 2
		}
	}

	private static func clamp(_ value: Float, ceiling: Float) -> Int16 {
		Int16(max(-ceiling, min(ceiling, value)) * 32_767)
	}
}

extension AudioProcessor.Parameters: Equatable {}
