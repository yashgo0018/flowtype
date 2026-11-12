import Foundation

struct MeetingChunk: Sendable {
    var source: MeetingSource
    var start: Double
    var samples: [Float]
    var end: Double { start + Double(samples.count) / RecordedAudio.sampleRate }
    var peak: Float { samples.reduce(0) { max($0, abs($1)) } }
}

/// Audio callbacks write here synchronously. No per-buffer Tasks or unbounded dispatch queue.
/// At most 2 partial chunks + 6 queued chunks + one consumer chunk (under 12 MB PCM).
final class MeetingAudioQueue: @unchecked Sendable {
    static let chunkFrames = 20 * 16_000
    static let capacity = 6
    private struct Partial {
        var start: Double = 0
        var samples: [Float] = []
        var lastEnd: Double?
        var received = 0
        var peak: Float = 0
    }
    private let lock = NSLock()
    private var partials: [MeetingSource: Partial] = [:]
    private var chunks: [MeetingChunk] = []
    private var issues: [MeetingIssue] = []
    private var closed = false

    func append(_ samples: [Float], source: MeetingSource, at start: Double) {
        lock.withLock {
            guard !closed, !samples.isEmpty, start.isFinite else { return }
            guard samples.count <= 65_536 else {
                notice(start, start, "Oversized \(source.title) buffer was dropped."); return
            }
            var partial = partials[source] ?? Partial()
            if let expected = partial.lastEnd, abs(start - expected) > 0.15 {
                enqueue(partial.samples, source: source, start: partial.start)
                partial.samples = []
                notice(min(expected, start), max(expected, start), "\(source.title) clock discontinuity; timestamps realigned.")
            }
            partial.received += samples.count
            partial.peak = max(partial.peak, samples.reduce(0) { max($0, abs($1)) })
            partial.lastEnd = start + Double(samples.count) / RecordedAudio.sampleRate
            var offset = 0
            while offset < samples.count {
                if partial.samples.isEmpty { partial.start = start + Double(offset) / RecordedAudio.sampleRate }
                let count = min(Self.chunkFrames - partial.samples.count, samples.count - offset)
                partial.samples.append(contentsOf: samples[offset..<(offset + count)])
                offset += count
                if partial.samples.count == Self.chunkFrames {
                    enqueue(partial.samples, source: source, start: partial.start)
                    partial.samples = []
                }
            }
            partials[source] = partial
        }
    }

    private func enqueue(_ samples: [Float], source: MeetingSource, start: Double) {
        guard !samples.isEmpty else { return }
        if chunks.count >= Self.capacity {
            notice(start, start + Double(samples.count) / RecordedAudio.sampleRate,
                   "\(source.title) audio lost: transcription could not keep up. This interval is missing.")
        } else { chunks.append(MeetingChunk(source: source, start: start, samples: samples)) }
    }

    private func notice(_ start: Double, _ end: Double, _ message: String) {
        if issues.count < 100 { issues.append(MeetingIssue(start: max(0, start), end: max(0, end), message: message)) }
        else { issues[99].end = max(issues[99].end, end); issues[99].message = "Additional capture gaps occurred in this interval." }
    }

    func report(_ message: String, at seconds: Double) {
        lock.withLock { notice(seconds, seconds, message) }
    }

    func pop() -> MeetingChunk? {
        lock.withLock {
            guard !chunks.isEmpty else { return nil }
            let index = chunks.indices.min { chunks[$0].start < chunks[$1].start }!
            return chunks.remove(at: index)
        }
    }

    func drainIssues() -> [MeetingIssue] { lock.withLock { let result = issues; issues = []; return result } }

    func finish() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            for source in MeetingSource.allCases {
                if var partial = partials[source] {
                    enqueue(partial.samples, source: source, start: partial.start)
                    partial.samples = []
                    partials[source] = partial
                }
            }
        }
    }

    func health(_ source: MeetingSource) -> (received: Int, peak: Float, lastEnd: Double?) {
        lock.withLock {
            let p = partials[source] ?? Partial()
            return (p.received, p.peak, p.lastEnd)
        }
    }

    var bufferedFrames: Int { lock.withLock { chunks.reduce(0) { $0 + $1.samples.count } + partials.values.reduce(0) { $0 + $1.samples.count } } }
}
