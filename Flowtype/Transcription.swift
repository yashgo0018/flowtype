import Foundation
@preconcurrency import WhisperKit

struct TranscriptionModelStatus: Equatable, Sendable {
    let modelName: String
    let isReady: Bool
    let localPath: String?
}

/// Fraction 0...1 while downloading, nil while loading into memory.
typealias ModelPreparationProgress = @Sendable (Double?) -> Void

@MainActor
protocol Transcribing: AnyObject {
    func transcribe(_ audio: RecordedAudio, settings: AppSettings, vocabulary: [String]) async throws -> String
    func modelStatus(settings: AppSettings) -> TranscriptionModelStatus
    /// Downloads (if needed) and loads the model so the next dictation starts instantly.
    func prepare(settings: AppSettings, progress: ModelPreparationProgress?) async throws
    func isLoaded(settings: AppSettings) -> Bool
    /// Releases the in-memory model; the next dictation loads it again.
    func unloadModel()
    func deleteDownloadedModels() throws
}

@MainActor
final class DefaultTranscriptionService: Transcribing {
    private let appleService: AppleSpeechTranscriptionService
    private let localService: WhisperKitTranscriptionService
    private let groqService: GroqTranscriptionService

    init(
        appleService: AppleSpeechTranscriptionService = AppleSpeechTranscriptionService(),
        localService: WhisperKitTranscriptionService = WhisperKitTranscriptionService(),
        groqService: GroqTranscriptionService = GroqTranscriptionService()
    ) {
        self.appleService = appleService
        self.localService = localService
        self.groqService = groqService
    }

    private func service(for settings: AppSettings) -> Transcribing {
        switch settings.transcriptionProvider {
        case .apple: appleService
        case .local: localService
        case .groq: groqService
        }
    }

    func transcribe(_ audio: RecordedAudio, settings: AppSettings, vocabulary: [String]) async throws -> String {
        try await service(for: settings).transcribe(audio, settings: settings, vocabulary: vocabulary)
    }

    func modelStatus(settings: AppSettings) -> TranscriptionModelStatus {
        service(for: settings).modelStatus(settings: settings)
    }

    func prepare(settings: AppSettings, progress: ModelPreparationProgress?) async throws {
        try await service(for: settings).prepare(settings: settings, progress: progress)
    }

    func isLoaded(settings: AppSettings) -> Bool {
        service(for: settings).isLoaded(settings: settings)
    }

    func unloadModel() {
        localService.unloadModel()
    }

    func deleteDownloadedModels() throws {
        try localService.deleteDownloadedModels()
    }
}

@MainActor
final class WhisperKitTranscriptionService: Transcribing {
    private var whisperKit: WhisperKit?
    private var loadedModelName: String?
    private var loadingTask: (model: String, task: Task<WhisperKit, Error>)?

    func transcribe(_ audio: RecordedAudio, settings: AppSettings, vocabulary: [String]) async throws -> String {
        let kit = try await loadKit(modelName: SettingsStore.normalizeTranscriptionModel(settings.transcriptionModel), progress: nil)
        let options = DecodingOptions(
            task: .transcribe,
            language: AppSettings.transcriptionLanguage,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            suppressBlank: true,
            chunkingStrategy: audio.duration > 28 ? .vad : ChunkingStrategy.none
        )
        let results: [TranscriptionResult] = try await kit.transcribe(audioArray: audio.samples, decodeOptions: options)
        try Task.checkCancellation()
        return results.map(\.text).joined(separator: " ")
    }

    func modelStatus(settings: AppSettings) -> TranscriptionModelStatus {
        let modelName = SettingsStore.normalizeTranscriptionModel(settings.transcriptionModel)
        let folder = localModelFolder(for: modelName)
        return TranscriptionModelStatus(
            modelName: modelName,
            isReady: folder != nil || loadedModelName == modelName,
            localPath: folder?.path
        )
    }

    func prepare(settings: AppSettings, progress: ModelPreparationProgress?) async throws {
        _ = try await loadKit(modelName: SettingsStore.normalizeTranscriptionModel(settings.transcriptionModel), progress: progress)
    }

    func isLoaded(settings: AppSettings) -> Bool {
        whisperKit != nil && loadedModelName == SettingsStore.normalizeTranscriptionModel(settings.transcriptionModel)
    }

    func unloadModel() {
        guard loadingTask == nil else { return }
        whisperKit = nil
        loadedModelName = nil
    }

    func deleteDownloadedModels() throws {
        whisperKit = nil
        loadedModelName = nil
        let models = try Self.appSupportDirectory().appendingPathComponent("models", isDirectory: true)
        if FileManager.default.fileExists(atPath: models.path) {
            try FileManager.default.removeItem(at: models)
        }
    }

    private func loadKit(modelName: String, progress: ModelPreparationProgress?) async throws -> WhisperKit {
        if let whisperKit, loadedModelName == modelName {
            return whisperKit
        }
        // Share one load between a background warm-up and a dictation that arrives meanwhile.
        if let loadingTask, loadingTask.model == modelName {
            return try await loadingTask.task.value
        }

        let existingFolder = localModelFolder(for: modelName)
        let task = Task<WhisperKit, Error> {
            try await Self.loadModel(modelName, existingFolder: existingFolder, progress: progress)
        }
        loadingTask = (modelName, task)
        defer {
            if loadingTask?.model == modelName {
                loadingTask = nil
            }
        }

        let kit = try await task.value
        whisperKit = kit
        loadedModelName = modelName
        return kit
    }

    nonisolated private static func loadModel(
        _ modelName: String,
        existingFolder: URL?,
        progress: ModelPreparationProgress?
    ) async throws -> WhisperKit {
        let base = try appSupportDirectory()
        let folder: URL
        if let existingFolder {
            folder = existingFolder
        } else {
            progress?(0)
            folder = try await WhisperKit.download(variant: modelName, downloadBase: base) { update in
                progress?(update.fractionCompleted)
            }
        }
        progress?(nil)
        let config = WhisperKitConfig(
            model: modelName,
            downloadBase: base,
            modelFolder: folder.path,
            verbose: false,
            logLevel: .error,
            load: true,
            download: false
        )
        return try await WhisperKit(config)
    }

    nonisolated private static func appSupportDirectory() throws -> URL {
        let folder = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Flowtype", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func localModelFolder(for modelName: String) -> URL? {
        guard let base = try? Self.appSupportDirectory() else { return nil }
        let candidates = [
            base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(modelName)", isDirectory: true),
            base.appendingPathComponent(modelName, isDirectory: true)
        ]
        return candidates.first(where: Self.containsRequiredModelFiles)
    }

    private static func containsRequiredModelFiles(_ folder: URL) -> Bool {
        let manager = FileManager.default
        let required = ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc", "config.json"]
        return required.allSatisfy { manager.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }
}

@MainActor
final class GroqTranscriptionService: Transcribing {
    private let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func transcribe(_ audio: RecordedAudio, settings: AppSettings, vocabulary: [String]) async throws -> String {
        let apiKey = settings.groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw GroqTranscriptionError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 45
        let boundary = "Boundary-\(UUID().uuidString)"
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(audio: audio, vocabulary: vocabulary, boundary: boundary)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw GroqTranscriptionError.offline
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GroqTranscriptionError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw GroqTranscriptionError.apiError(statusCode: httpResponse.statusCode, message: Self.errorMessage(from: data))
        }

        return try JSONDecoder().decode(GroqTranscriptionResponse.self, from: data).text
    }

    func modelStatus(settings: AppSettings) -> TranscriptionModelStatus {
        TranscriptionModelStatus(
            modelName: AppSettings.groqTranscriptionModel,
            isReady: settings.hasGroqAPIKey,
            localPath: nil
        )
    }

    func prepare(settings: AppSettings, progress: ModelPreparationProgress?) async throws {}

    func isLoaded(settings: AppSettings) -> Bool {
        settings.hasGroqAPIKey
    }

    func unloadModel() {}

    func deleteDownloadedModels() throws {}

    private static func multipartBody(audio: RecordedAudio, vocabulary: [String], boundary: String) -> Data {
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }

        appendField("model", AppSettings.groqTranscriptionModel)
        appendField("response_format", "json")
        appendField("language", AppSettings.transcriptionLanguage)
        appendField("temperature", "0")
        // Whisper's prompt is limited to 224 tokens; a short vocabulary list stays well inside it.
        let prompt = vocabulary.prefix(60).joined(separator: ", ")
        if !prompt.isEmpty {
            appendField("prompt", String(prompt.prefix(600)))
        }

        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio.wavData())
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private static func errorMessage(from data: Data) -> String {
        if let response = try? JSONDecoder().decode(GroqErrorResponse.self, from: data),
           let message = response.error?.message,
           !message.isEmpty {
            return message
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error."
    }
}

private struct GroqTranscriptionResponse: Decodable {
    let text: String
}

private struct GroqErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String?
    }

    let error: APIError?
}

enum GroqTranscriptionError: LocalizedError {
    case missingAPIKey
    case offline
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add a Groq API key in Settings, or switch to on-device transcription."
        case .offline:
            "You're offline. Switch to on-device transcription to dictate without internet."
        case .invalidResponse:
            "Groq returned an invalid response."
        case .apiError(401, _):
            "Groq rejected the API key. Check it in Settings."
        case .apiError(429, _):
            "Groq rate limit reached. Try again in a moment."
        case .apiError(let statusCode, let message):
            "Groq error \(statusCode): \(message)"
        }
    }
}
