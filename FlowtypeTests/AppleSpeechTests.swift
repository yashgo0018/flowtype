import AVFoundation
import XCTest
@testable import Flowtype

/// Runs real speech through Flowtype's Apple speech path. Skipped on Macs without Apple speech.
@MainActor
final class AppleSpeechTests: XCTestCase {
    func testTranscribesSpokenAudio() async throws {
        try XCTSkipUnless(AppleSpeech.isSupported, "Apple speech recognition isn't available on this Mac.")

        let audio = try spokenAudio("Let's ship the launch checklist on Thursday morning.")
        let service = AppleSpeechTranscriptionService()
        try await service.prepare(settings: AppSettings.defaults, progress: nil)
        let text = try await service.transcribe(audio, settings: AppSettings.defaults, vocabulary: ["Thursday"])

        let normalized = text.lowercased()
        XCTAssertTrue(normalized.contains("checklist"), "Got: \(text)")
        XCTAssertTrue(normalized.contains("thursday"), "Got: \(text)")
        XCTAssertTrue(service.isLoaded(settings: AppSettings.defaults))
    }

    func testMeetingFinalRangesPreserveSourceAndSessionOffset() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Meeting Apple Speech requires macOS 26.") }
        try XCTSkipUnless(AppleSpeech.isSupported, "Apple Speech is unavailable on this Mac.")
        let audio = try spokenAudio("The meeting checklist is ready for Thursday morning.")
        try await AppleSpeechTranscriptionService.prepareMeeting(locale: "en-US")
        let chunk = MeetingChunk(source: .system, start: 12.5, samples: audio.samples)
        let segments = try await AppleSpeechTranscriptionService.transcribeMeeting(chunk, locale: "en-US")
        XCTAssertFalse(segments.isEmpty)
        XCTAssertTrue(segments.map(\.text).joined(separator: " ").lowercased().contains("checklist"))
        for segment in segments {
            XCTAssertEqual(segment.source, .system)
            XCTAssertGreaterThanOrEqual(segment.start, chunk.start)
            XCTAssertLessThanOrEqual(segment.end, chunk.end + 0.1)
            XCTAssertGreaterThanOrEqual(segment.end, segment.start)
        }
    }

    /// Synthesizes speech with macOS's `say` and converts it to Flowtype's 16 kHz mono recording format.
    private func spokenAudio(_ sentence: String) throws -> RecordedAudio {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flowtype-apple-speech-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, sentence]
        try say.run()
        say.waitUntilExit()

        let file = try AVAudioFile(forReading: url)
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: source)
        let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: RecordedAudio.sampleRate, channels: 1, interleaved: false))
        let converter = try XCTUnwrap(AVAudioConverter(from: file.processingFormat, to: target))
        let capacity = AVAudioFrameCount(Double(source.frameLength) * RecordedAudio.sampleRate / file.processingFormat.sampleRate) + 1024
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity))
        var supplied = false
        _ = converter.convert(to: output, error: nil) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true
            status.pointee = .haveData
            return source
        }
        let samples = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        return RecordedAudio(samples: samples, peakLevel: samples.map(abs).max() ?? 0)
    }
}
