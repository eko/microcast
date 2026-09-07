import XCTest
@testable import MicroCast

final class AudioProcessorTests: XCTestCase {
	/// Interleaved stereo sine at a given amplitude.
	private func sine(amplitude: Float, frames: Int = 48_000) -> [Int16] {
		(0..<frames).flatMap { frame -> [Int16] in
			let value = Int16(amplitude * 32_767 * sin(2 * .pi * 440 * Float(frame) / 48_000))
			return [value, value]
		}
	}

	private func peak(_ samples: [Int16]) -> Float { Float(samples.map { abs(Int($0)) }.max() ?? 0) / 32_767 }
	private func rms(_ samples: [Int16]) -> Float {
		sqrt(samples.reduce(Float(0)) { $0 + pow(Float($1) / 32_767, 2) } / Float(samples.count))
	}

	func testOffLeavesAudioUntouched() {
		var processor = AudioProcessor(preset: .off)
		XCTAssertFalse(processor.isActive)
		var samples = sine(amplitude: 0.2, frames: 100)
		let original = samples
		samples.withUnsafeMutableBufferPointer { processor.process($0) }
		XCTAssertEqual(samples, original)
	}

	func testBroadcastPresetMakesQuietAudioSubstantiallyLouder() {
		var processor = AudioProcessor(preset: .broadcast)
		XCTAssertTrue(processor.isActive)
		var samples = sine(amplitude: 0.1) // a quiet source, like the raw capture
		let before = rms(samples)
		samples.withUnsafeMutableBufferPointer { processor.process($0) }
		let after = rms(Array(samples.suffix(48_000))) // past the look-ahead priming
		let gainDB = 20 * log10(after / before)
		XCTAssertGreaterThan(gainDB, 6, "broadcast preset should add real loudness")
		XCTAssertLessThan(peak(samples), 0.98, "and never exceed the ceiling")
	}

	func testLimiterKeepsLoudInputBelowTheCeiling() {
		var processor = AudioProcessor(preset: .loud)
		var samples = sine(amplitude: 0.95)
		samples.withUnsafeMutableBufferPointer { processor.process($0) }
		XCTAssertLessThanOrEqual(peak(samples), 0.98, "a hot input must not clip")
	}

	func testSafetyLimiterTamesClippingWithoutAddingLoudness() {
		var processor = AudioProcessor(preset: .limiter)
		var hot = sine(amplitude: 1.0)
		hot.withUnsafeMutableBufferPointer { processor.process($0) }
		XCTAssertLessThanOrEqual(peak(hot), 0.98, "a source pinned at full scale is brought under the ceiling")

		var quiet = AudioProcessor(preset: .limiter)
		var samples = sine(amplitude: 0.2)
		let before = rms(samples)
		samples.withUnsafeMutableBufferPointer { quiet.process($0) }
		let after = rms(Array(samples.suffix(48_000)))
		XCTAssertEqual(20 * log10(after / before), 0, accuracy: 0.5, "quiet audio is left at its own level")
	}

	func testPresetsAreOrderedByLoudness() {
		var results: [Float] = []
		for preset in [AudioProcessor.Preset.light, .broadcast, .loud] {
			var processor = AudioProcessor(preset: preset)
			var samples = sine(amplitude: 0.1)
			samples.withUnsafeMutableBufferPointer { processor.process($0) }
			results.append(rms(Array(samples.suffix(48_000))))
		}
		XCTAssertLessThan(results[0], results[1], "broadcast is louder than light")
		XCTAssertLessThan(results[1], results[2], "loud is louder than broadcast")
	}
}
