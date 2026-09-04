import Foundation

struct HLSPart {
	let index: Int
	let duration: Double
	let data: Data
}

final class HLSSegment {
	let sequence: Int
	let programDate: Date
	var parts: [HLSPart] = []
	var complete = false

	init(sequence: Int, programDate: Date) {
		self.sequence = sequence
		self.programDate = programDate
	}

	var duration: Double { parts.reduce(0) { $0 + $1.duration } }
	var data: Data { parts.reduce(into: Data()) { $0.append($1.data) } }
}

/// The live media playlist of one rendition, with Low-Latency HLS partial segments and blocking reloads.
final class LivePlaylist: @unchecked Sendable {
	/// Advertised PART-TARGET: the requested part length plus one AAC frame, since parts are cut on frame boundaries.
	let partTarget: Double
	let partsPerSegment: Int
	let targetDuration: Int
	/// Goes into the title field of every EXTINF line.
	let title: String
	private let window = 6

	private let lock = NSLock()
	private var initSegment: Data?
	private var segments: [HLSSegment] = []
	private var nextSequence = 0
	private var waiters: [Waiter] = []

	private struct Waiter {
		let id: UUID
		let sequence: Int
		let part: Int?
		let continuation: CheckedContinuation<Void, Never>
	}

	init(partDuration: Double, segmentDuration: Double, title: String) {
		self.title = title.replacingOccurrences(of: "\n", with: " ")
		partTarget = ((partDuration + 1024.0 / Double(AudioCapture.sampleRate)) * 1000).rounded(.up) / 1000
		partsPerSegment = max(1, Int((segmentDuration / partDuration).rounded()))
		targetDuration = Int((Double(partsPerSegment) * partTarget).rounded(.up))
	}

	var initialization: Data? {
		lock.withLock { initSegment }
	}

	var hasContent: Bool {
		lock.withLock { initSegment != nil && !segments.isEmpty }
	}

	func setInitialization(_ data: Data) {
		lock.withLock { initSegment = data }
	}

	func add(part data: Data, duration: Double) {
		let ready: [Waiter] = lock.withLock {
			if segments.last?.complete ?? true {
				segments.append(HLSSegment(sequence: nextSequence, programDate: Date()))
				nextSequence += 1
			}
			let segment = segments[segments.count - 1]
			segment.parts.append(HLSPart(index: segment.parts.count, duration: duration, data: data))
			if segment.parts.count >= partsPerSegment { segment.complete = true }
			if segments.count > window + 1 { segments.removeFirst(segments.count - window - 1) }
			let satisfied = waiters.filter { isSatisfied(sequence: $0.sequence, part: $0.part) }
			let ids = Set(satisfied.map(\.id))
			waiters.removeAll { ids.contains($0.id) }
			return satisfied
		}
		ready.forEach { $0.continuation.resume() }
	}

	func part(sequence: Int, index: Int) -> Data? {
		lock.withLock {
			guard let segment = segments.first(where: { $0.sequence == sequence }), index < segment.parts.count else { return nil }
			return segment.parts[index].data
		}
	}

	func segment(sequence: Int) -> Data? {
		lock.withLock { segments.first { $0.sequence == sequence && $0.complete }?.data }
	}

	/// Returns once the playlist contains the requested segment (or part of it), or after `timeout` seconds.
	func wait(forSequence sequence: Int, part: Int?, timeout: TimeInterval) async {
		let id = UUID()
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			let done: Bool = lock.withLock {
				if isSatisfied(sequence: sequence, part: part) { return true }
				waiters.append(Waiter(id: id, sequence: sequence, part: part, continuation: continuation))
				return false
			}
			if done {
				continuation.resume()
				return
			}
			DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.expire(id) }
		}
	}

	func render() -> String {
		lock.withLock { () -> String in
			var lines = [
				"#EXTM3U",
				"#EXT-X-VERSION:6",
				"#EXT-X-TARGETDURATION:\(targetDuration)",
				"#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=\(Self.format(partTarget * 3))",
				"#EXT-X-PART-INF:PART-TARGET=\(Self.format(partTarget))",
				"#EXT-X-MEDIA-SEQUENCE:\(segments.first?.sequence ?? nextSequence)",
				"#EXT-X-MAP:URI=\"init.mp4\"",
			]
			for segment in segments {
				lines.append("#EXT-X-PROGRAM-DATE-TIME:\(Self.dateFormatter.string(from: segment.programDate))")
				for part in segment.parts {
					lines.append("#EXT-X-PART:DURATION=\(Self.format(part.duration)),URI=\"seg\(segment.sequence).\(part.index).m4s\",INDEPENDENT=YES")
				}
				if segment.complete {
					lines.append("#EXTINF:\(Self.format(segment.duration)),\(title)")
					lines.append("seg\(segment.sequence).m4s")
				}
			}
			if let last = segments.last {
				let hint = last.complete ? "seg\(last.sequence + 1).0.m4s" : "seg\(last.sequence).\(last.parts.count).m4s"
				lines.append("#EXT-X-PRELOAD-HINT:TYPE=PART,URI=\"\(hint)\"")
			}
			return lines.joined(separator: "\n") + "\n"
		}
	}

	private func expire(_ id: UUID) {
		let waiter: Waiter? = lock.withLock {
			guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
			return waiters.remove(at: index)
		}
		waiter?.continuation.resume()
	}

	/// Call with the lock held. "Satisfied" also covers requests that can never be met, so they get an answer now.
	private func isSatisfied(sequence: Int, part: Int?) -> Bool {
		guard let segment = segments.first(where: { $0.sequence == sequence }) else {
			let first = segments.first?.sequence ?? 0
			let last = segments.last?.sequence ?? -1
			return sequence < first || sequence > last + 2 // already dropped, or too far ahead to wait for
		}
		if let part { return segment.parts.count > part || (segment.complete && part >= segment.parts.count) }
		return segment.complete
	}

	private static func format(_ seconds: Double) -> String {
		String(format: "%.3f", seconds)
	}

	private static let dateFormatter: ISO8601DateFormatter = {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return formatter
	}()
}
