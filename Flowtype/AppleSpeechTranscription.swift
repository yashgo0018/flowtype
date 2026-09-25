import AVFoundation
import Foundation
import Speech

/// Apple's on-device speech model (SpeechAnalyzer, macOS 26+). The model is managed and shared by
/// macOS, so on supported Macs dictation works without downloading anything.
enum AppleSpeech {
    /// Whether this Mac can run Apple's on-device speech model.
    static var isSupported: Bool {
        guard #available(macOS 26, *) else { return false }
        return SpeechTranscriber.isAvailable
    }

    /// English locale to transcribe in, following the user's region (en-GB, en-IN, …) when possible.
    static var preferredLocale: Locale {
        Locale.current.language.languageCode == .english ? Locale.current : Locale(identifier: "en-US")
    }
}

enum AppleSpeechError: LocalizedError {
    case unsupported
    case unsupportedLocale
    case audioFormat

    var errorDescription: String? {
        switch self {
        case .unsupported: "Apple speech recognition needs macOS 26 or later on a supported Mac."
        case .unsupportedLocale: "Apple speech recognition doesn't support English on this Mac."
        case .audioFormat: "The recording couldn't be converted for Apple speech recognition."
        }
    }
}

@MainActor
final class AppleSpeechTranscriptionService: Transcribing {
    /// Set once macOS confirms the English model is installed for this app.
    private var assetsReady = false

    func transcribe(_ audio: RecordedAudio, settings: AppSettings, vocabulary: [String]) async throws -> String {
        guard #available(macOS 26, *) else { throw AppleSpeechError.unsupported }
        let text = try await Self.transcribe(
            samples: audio.samples,
            locale: AppleSpeech.preferredLocale,
            vocabulary: vocabulary,
            ensureAssets: !assetsReady
        )
        assetsReady = true
        return text
    }

    func modelStatus(settings: AppSettings) -> TranscriptionModelStatus {
        TranscriptionModelStatus(modelName: "Apple Speech", isReady: AppleSpeech.isSupported, localPath: nil)
    }

    func prepare(settings: AppSettings, progress: ModelPreparationProgress?) async throws {
        guard #available(macOS 26, *) else { throw AppleSpeechError.unsupported }
        try await Self.installAssets(locale: AppleSpeech.preferredLocale, progress: progress)
        assetsReady = true
    }

    func isLoaded(settings: AppSettings) -> Bool {
        assetsReady
    }

    /// macOS owns the model's lifetime and memory; there is nothing for the app to unload.
    func unloadModel() {}

    /// The model belongs to macOS and is shared with other apps, so Flowtype doesn't delete it.
    func deleteDownloadedModels() throws {}

    // MARK: - Speech framework (runs off the main actor)

    @available(macOS 26, *)
    nonisolated private static func transcriber(for locale: Locale) async throws -> SpeechTranscriber {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw AppleSpeechError.unsupportedLocale
        }
        return SpeechTranscriber(locale: supported, preset: .transcription)
    }

    /// Makes sure macOS has the speech model for `locale`. Usually already installed (it's shared
    /// with system dictation); otherwise macOS downloads it and we report progress.
    @available(macOS 26, *)
    nonisolated private static func installAssets(locale: Locale, progress: ModelPreparationProgress?) async throws {
        let transcriber = try await transcriber(for: locale)
        if let supported = transcriber.selectedLocales.first {
            _ = try? await AssetInventory.reserve(locale: supported)
        }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return
        }
        let reporter = Task {
            while !Task.isCancelled {
                progress?(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { reporter.cancel() }
        try await request.downloadAndInstall()
    }

    @available(macOS 26, *)
    nonisolated private static func transcribe(samples: [Float], locale: Locale, vocabulary: [String], ensureAssets: Bool) async throws -> String {
        if ensureAssets {
            try await installAssets(locale: locale, progress: nil)
        }
        let transcriber = try await transcriber(for: locale)

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let buffer = convert(samples, to: analyzerFormat) else {
            throw AppleSpeechError.audioFormat
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            // Vocabulary is a hint; transcription still works if the model ignores it.
            try? await analyzer.setContext(context)
        }

        let results = transcriber.results
        let collector = Task {
            var text = ""
            for try await result in results {
                text += String(result.text.characters)
            }
            return text
        }

        let (input, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()
        do {
            _ = try await analyzer.analyzeSequence(input)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        return try await collector.value
    }

    /// Converts Flowtype's 16 kHz mono float samples into the analyzer's preferred format.
    nonisolated private static func convert(_ samples: [Float], to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: RecordedAudio.sampleRate,
            channels: 1,
            interleaved: false
        ),
            let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = source.floatChannelData?[0] else {
            return nil
        }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }

        guard let converter = AVAudioConverter(from: sourceFormat, to: format) else { return nil }
        let capacity = AVAudioFrameCount(Double(samples.count) * format.sampleRate / RecordedAudio.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        let supplied = SuppliedOnce()
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied.done {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied.done = true
            inputStatus.pointee = .haveData
            return source
        }
        return status == .error ? nil : output
    }
}

private final class SuppliedOnce: @unchecked Sendable {
    var done = false
}
