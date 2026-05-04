import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import CoreGraphics
import Foundation
@preconcurrency import WhisperKit

struct CapturedAudio: Sendable {
    let url: URL
    let peakLevel: Float
}

struct PasteOutcome: Equatable, Sendable {
    let pasted: Bool
    let message: String
}

struct PasteTarget: @unchecked Sendable {
    let processIdentifier: pid_t
    let focusedElement: AXUIElement?
    let role: String?
}


struct TranscriptionModelStatus: Equatable, Sendable {
    let modelName: String
    let isDownloaded: Bool
    let localPath: String?
}

protocol AudioCapturing {
    var isRecording: Bool { get }
    func start() throws
    func stop() throws -> CapturedAudio?
    func cancel()
}

@MainActor
protocol Transcribing: AnyObject {
    func transcribe(audioURL: URL, settings: AppSettings) async throws -> String
    func modelStatus(settings: AppSettings) -> TranscriptionModelStatus
    func downloadModel(settings: AppSettings) async throws -> TranscriptionModelStatus
}

@MainActor
protocol Pasting {
    func capturePasteTarget() -> PasteTarget?
    func paste(_ text: String, restoreClipboard: Bool, target: PasteTarget?) -> PasteOutcome
}

@MainActor
final class DefaultTranscriptionService: Transcribing {
    private let localService: WhisperKitTranscriptionService
    private let groqService: GroqTranscriptionService

    init(
        localService: WhisperKitTranscriptionService = WhisperKitTranscriptionService(),
        groqService: GroqTranscriptionService = GroqTranscriptionService()
    ) {
        self.localService = localService
        self.groqService = groqService
    }

    func transcribe(audioURL: URL, settings: AppSettings) async throws -> String {
        switch settings.transcriptionProvider {
        case .local:
            try await localService.transcribe(audioURL: audioURL, settings: settings)
        case .groq:
            try await groqService.transcribe(audioURL: audioURL, settings: settings)
        }
    }

    func modelStatus(settings: AppSettings) -> TranscriptionModelStatus {
        switch settings.transcriptionProvider {
        case .local:
            localService.modelStatus(settings: settings)
        case .groq:
            groqService.modelStatus(settings: settings)
        }
    }

    func downloadModel(settings: AppSettings) async throws -> TranscriptionModelStatus {
        switch settings.transcriptionProvider {
        case .local:
            try await localService.downloadModel(settings: settings)
        case .groq:
            try await groqService.downloadModel(settings: settings)
        }
    }
}

final class AudioCaptureService: AudioCapturing {
    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var peakLevel: Float = 0

    var isRecording: Bool { engine.isRunning }

    func start() throws {
        guard !engine.isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowtype-native-\(Int(Date().timeIntervalSince1970 * 1000))")
            .appendingPathExtension("wav")
        outputURL = tempURL
        peakLevel = 0
        audioFile = try AVAudioFile(forWriting: tempURL, settings: format.settings)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            try? self.audioFile?.write(from: buffer)
            self.peakLevel = max(self.peakLevel, Self.peakLevel(for: buffer))
        }

        engine.prepare()
        try engine.start()
    }

    func stop() throws -> CapturedAudio? {
        guard engine.isRunning else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil
        guard let outputURL else { return nil }
        self.outputURL = nil
        guard peakLevel >= 0.001 else {
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
        return CapturedAudio(url: outputURL, peakLevel: peakLevel)
    }

    func cancel() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioFile = nil
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
        peakLevel = 0
    }

    private static func peakLevel(for buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var peak: Float = 0
        for channel in 0..<channels {
            let samples = data[channel]
            for frame in 0..<frames {
                peak = max(peak, abs(samples[frame]))
            }
        }
        return peak
    }
}

@MainActor
final class WhisperKitTranscriptionService: Transcribing {
    private var whisperKit: WhisperKit?
    private var loadedModelName: String?
    private var loadedModelFolder: URL?

    func transcribe(audioURL: URL, settings: AppSettings) async throws -> String {
        let kit = try await loadKit(settings: settings)
        let options = DecodingOptions(
            task: .transcribe,
            language: "en",
            usePrefillPrompt: true,
            detectLanguage: false,
            withoutTimestamps: true
        )
        let result = try await kit.transcribe(audioPath: audioURL.path, decodeOptions: options)
        let text = result.map(\.text).joined(separator: " ")
        return normalizeTranscript(text)
    }

    func modelStatus(settings: AppSettings) -> TranscriptionModelStatus {
        let modelName = normalizedEnglishModel(settings.transcriptionModel)
        let localFolder = localModelFolder(for: modelName)
        return TranscriptionModelStatus(
            modelName: modelName,
            isDownloaded: localFolder != nil || loadedModelName == modelName,
            localPath: localFolder?.path ?? loadedModelFolder?.path
        )
    }

    func downloadModel(settings: AppSettings) async throws -> TranscriptionModelStatus {
        _ = try await loadKit(settings: settings)
        return modelStatus(settings: settings)
    }

    private func loadKit(settings: AppSettings) async throws -> WhisperKit {
        let modelName = normalizedEnglishModel(settings.transcriptionModel)
        if let whisperKit, loadedModelName == modelName {
            return whisperKit
        }
        let appSupport = try appSupportDirectory(create: true)
        let config = WhisperKitConfig(
            model: modelName,
            downloadBase: appSupport,
            load: true,
            download: true
        )
        let kit = try await WhisperKit(config)
        whisperKit = kit
        loadedModelName = modelName
        loadedModelFolder = localModelFolder(for: modelName)
        return kit
    }

    private func normalizedEnglishModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(".en") {
            return trimmed
        }
        return AppSettings.defaultTranscriptionModel
    }

    private func appSupportDirectory(create: Bool) throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: create
        ).appendingPathComponent("Flowtype", isDirectory: true)
        if create {
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        }
        return appSupport
    }

    private func localModelFolder(for modelName: String) -> URL? {
        guard let appSupport = try? appSupportDirectory(create: false) else { return nil }
        guard isDirectory(appSupport) else {
            return nil
        }

        let likelyFolders = [
            appSupport.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(modelName)", isDirectory: true),
            appSupport.appendingPathComponent(modelName, isDirectory: true),
            appSupport.appendingPathComponent(modelName.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
        ]
        if let folder = likelyFolders.first(where: containsRequiredModelFiles) {
            return folder
        }

        guard let enumerator = FileManager.default.enumerator(
            at: appSupport,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator {
            guard url.lastPathComponent == modelName || url.path.contains("/\(modelName)/") else { continue }
            if containsRequiredModelFiles(url) {
                return url
            }
        }
        return nil
    }

    private func containsRequiredModelFiles(_ folder: URL) -> Bool {
        guard isDirectory(folder) else {
            return false
        }

        let requiredDirectories = ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"]
        let hasCompiledModels = requiredDirectories.allSatisfy { name in
            isDirectory(folder.appendingPathComponent(name, isDirectory: true))
        }
        let hasConfig = FileManager.default.fileExists(atPath: folder.appendingPathComponent("config.json").path)
        return hasCompiledModels && hasConfig
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

@MainActor
final class GroqTranscriptionService: Transcribing {
    private let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func transcribe(audioURL: URL, settings: AppSettings) async throws -> String {
        let apiKey = settings.groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw GroqTranscriptionError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        let boundary = "Boundary-\(UUID().uuidString)"
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try multipartBody(audioURL: audioURL, boundary: boundary)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GroqTranscriptionError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw GroqTranscriptionError.apiError(statusCode: httpResponse.statusCode, message: errorMessage(from: data))
        }

        let transcription = try JSONDecoder().decode(GroqTranscriptionResponse.self, from: data)
        return normalizeTranscript(transcription.text)
    }

    func modelStatus(settings: AppSettings) -> TranscriptionModelStatus {
        let hasAPIKey = !settings.groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return TranscriptionModelStatus(
            modelName: AppSettings.groqTranscriptionModel,
            isDownloaded: hasAPIKey,
            localPath: nil
        )
    }

    func downloadModel(settings: AppSettings) async throws -> TranscriptionModelStatus {
        modelStatus(settings: settings)
    }

    private func multipartBody(audioURL: URL, boundary: String) throws -> Data {
        var body = Data()
        appendField(name: "model", value: AppSettings.groqTranscriptionModel, to: &body, boundary: boundary)
        appendField(name: "response_format", value: "json", to: &body, boundary: boundary)
        appendField(name: "language", value: "en", to: &body, boundary: boundary)
        appendField(name: "temperature", value: "0", to: &body, boundary: boundary)

        let audioData = try Data(contentsOf: audioURL)
        body.append("--\(boundary)\r\n".utf8Data)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\n".utf8Data)
        body.append("Content-Type: \(mimeType(for: audioURL))\r\n\r\n".utf8Data)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".utf8Data)
        return body
    }

    private func appendField(name: String, value: String, to body: inout Data, boundary: String) {
        body.append("--\(boundary)\r\n".utf8Data)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8Data)
        body.append("\(value)\r\n".utf8Data)
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "flac":
            "audio/flac"
        case "mp3", "mpeg", "mpga":
            "audio/mpeg"
        case "m4a", "mp4":
            "audio/mp4"
        case "ogg":
            "audio/ogg"
        case "webm":
            "audio/webm"
        default:
            "audio/wav"
        }
    }

    private func errorMessage(from data: Data) -> String {
        if let response = try? JSONDecoder().decode(GroqErrorResponse.self, from: data),
           let message = response.error?.message,
           !message.isEmpty {
            return message
        }
        return String(data: data, encoding: .utf8) ?? "Unknown Groq API error."
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

private enum GroqTranscriptionError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Groq is selected, but no Groq API key is configured."
        case .invalidResponse:
            "Groq returned an invalid response."
        case .apiError(let statusCode, let message):
            "Groq API error \(statusCode): \(message)"
        }
    }
}

private func normalizeTranscript(_ text: String) -> String {
    text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private extension String {
    var utf8Data: Data {
        Data(utf8)
    }
}

@MainActor
final class PasteService: Pasting {
    private var lastTextTarget: PasteTarget?
    private var lastTextTargetDate: Date?
    private var focusPollTimer: Timer?

    init() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshLastTextTarget()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        focusPollTimer = timer
    }

    func capturePasteTarget() -> PasteTarget? {
        switch currentFocusTarget() {
        case .text(let target):
            rememberTextTarget(target)
            return target
        case .ownApp, .unavailable:
            return recentTextTarget()
        }
    }

    private enum FocusTarget {
        case text(PasteTarget)
        case ownApp
        case unavailable
    }

    private func refreshLastTextTarget() {
        guard PermissionService.hasAccessibilityPermission(prompt: false) else { return }
        if case .text(let target) = currentFocusTarget() {
            rememberTextTarget(target)
        }
    }

    private func rememberTextTarget(_ target: PasteTarget) {
        lastTextTarget = target
        lastTextTargetDate = .now
    }

    private func clearRememberedTarget() {
        lastTextTarget = nil
        lastTextTargetDate = nil
    }

    private func recentTextTarget() -> PasteTarget? {
        guard let lastTextTarget, let lastTextTargetDate else { return nil }
        guard Date().timeIntervalSince(lastTextTargetDate) < 120 else {
            clearRememberedTarget()
            return nil
        }
        return lastTextTarget
    }

    private func currentFocusTarget() -> FocusTarget {
        guard PermissionService.hasAccessibilityPermission(prompt: false) else {
            return .unavailable
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let focusedElement: AXUIElement?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let focused {
            focusedElement = (focused as! AXUIElement)
        } else {
            focusedElement = nil
        }

        let appPID = ProcessInfo.processInfo.processIdentifier
        let focusedPID = focusedElement.flatMap { element -> pid_t? in
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success else { return nil }
            return pid
        }

        if focusedPID == appPID {
            return .ownApp
        }

        guard let focusedElement, let resolvedPID = focusedPID, resolvedPID != appPID else {
            return .unavailable
        }

        let role = role(for: focusedElement)
        guard isTextEntryElement(focusedElement, role: role) else {
            return .unavailable
        }

        return .text(PasteTarget(processIdentifier: resolvedPID, focusedElement: focusedElement, role: role))
    }

    func paste(_ text: String, restoreClipboard: Bool, target: PasteTarget?) -> PasteOutcome {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return PasteOutcome(pasted: false, message: "No speech detected.")
        }

        let target = target ?? capturePasteTarget()

        guard let target, target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(cleaned, forType: .string) else {
                return PasteOutcome(pasted: false, message: "Could not write transcript to clipboard.")
            }
            return PasteOutcome(pasted: false, message: "Copied transcript to clipboard. No focused field detected.")
        }

        Self.reactivateTarget(target)
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        guard pasteboard.setString(cleaned, forType: .string) else {
            return PasteOutcome(pasted: false, message: "Could not write transcript to clipboard.")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            Self.sendCommandV()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            Self.removeTemporaryTranscriptFromClipboard(
                cleaned,
                previous: previous,
                restorePrevious: restoreClipboard,
                pasteboard: pasteboard
            )
        }

        return PasteOutcome(pasted: true, message: "Pasted transcript.")
    }

    private static func removeTemporaryTranscriptFromClipboard(
        _ transcript: String,
        previous: String?,
        restorePrevious: Bool,
        pasteboard: NSPasteboard
    ) {
        guard pasteboard.string(forType: .string) == transcript else { return }
        pasteboard.clearContents()
        if restorePrevious, let previous {
            pasteboard.setString(previous, forType: .string)
        }
    }

    private static func numberOfCharacters(for element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.intValue
    }

    private static func selectedTextRange(for element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let axValue = value else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue((axValue as! AXValue), .cfRange, &range) else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }

    private static func reactivateTarget(_ target: PasteTarget) {
        if let app = NSRunningApplication(processIdentifier: target.processIdentifier) {
            app.activate()
        }
        if let focusedElement = target.focusedElement {
            AXUIElementSetAttributeValue(
                AXUIElementCreateSystemWide(),
                kAXFocusedUIElementAttribute as CFString,
                focusedElement
            )
        }
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func role(for element: AXUIElement) -> String? {
        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        return roleValue as? String
    }

    private func isTextEntryElement(_ element: AXUIElement, role: String?) -> Bool {
        let textRoles = [
            kAXTextFieldRole,
            kAXTextAreaRole,
            kAXComboBoxRole
        ] as [String]
        if let role, textRoles.contains(role) {
            return true
        }
        return Self.selectedTextRange(for: element) != nil || Self.numberOfCharacters(for: element) != nil
    }
}

enum PermissionService {
    static func hasAccessibilityPermission(prompt: Bool = false) -> Bool {
        if prompt {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func microphoneAuthorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }
}

final class HotKeyService: @unchecked Sendable {
    var onToggle: (() -> Void)?
    var onHoldStart: (() -> Void)?
    var onHoldStop: (() -> Void)?
    var onCancel: (() -> Void)?

    private var settings = AppSettings.defaults
    private var toggleShortcut: ParsedShortcut?
    private var cancelShortcut: ParsedShortcut?
    private var carbonHotKey: EventHotKeyRef?
    private var carbonHandler: EventHandlerRef?
    private var carbonCallback: EventHandlerUPP?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var holdActive = false
    private var lastToggleAt = Date.distantPast

    func start(settings: AppSettings) throws {
        stop()
        self.settings = settings
        toggleShortcut = try ShortcutParser.parse(settings.toggleShortcut)
        cancelShortcut = try ShortcutParser.parse(settings.cancelShortcut, allowBareEscape: true)
        do {
            try registerCarbonToggleHotKey()
        } catch {
            NSLog("Flowtype hotkey registration warning: \(error.localizedDescription)")
        }
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let carbonHotKey {
            UnregisterEventHotKey(carbonHotKey)
        }
        if let carbonHandler {
            RemoveEventHandler(carbonHandler)
        }
        carbonHotKey = nil
        carbonHandler = nil
        carbonCallback = nil
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        holdActive = false
    }

    private func handle(_ event: NSEvent) {
        if event.type == .flagsChanged {
            handleHold(event)
            return
        }
        guard event.type == .keyDown else { return }
        if let toggleShortcut, ShortcutParser.matches(event, shortcut: toggleShortcut) {
            emitToggle()
            return
        }
        if let cancelShortcut, ShortcutParser.matches(event, shortcut: cancelShortcut) {
            onCancel?()
        }
    }

    private func handleHold(_ event: NSEvent) {
        let wantsFn = ["fn", "function", "globe"].contains(settings.holdShortcut.lowercased())
        guard wantsFn else { return }
        let isDown = event.modifierFlags.contains(.function)
        if isDown && !holdActive {
            holdActive = true
            onHoldStart?()
        } else if !isDown && holdActive {
            holdActive = false
            onHoldStop?()
        }
    }

    private func emitToggle() {
        guard Date().timeIntervalSince(lastToggleAt) > 0.35 else { return }
        lastToggleAt = Date()
        onToggle?()
    }

    private func registerCarbonToggleHotKey() throws {
        guard let toggleShortcut else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        carbonCallback = { _, _, userData in
            guard let userData else { return noErr }
            let service = Unmanaged<HotKeyService>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                service.emitToggle()
            }
            return noErr
        }

        let target = GetApplicationEventTarget()
        let handlerStatus = InstallEventHandler(
            target,
            carbonCallback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &carbonHandler
        )
        guard handlerStatus == noErr else {
            throw ShortcutError.registrationFailed("InstallEventHandler failed with status \(handlerStatus).")
        }

        let hotKeyID = EventHotKeyID(signature: fourCharCode("FLTY"), id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(toggleShortcut.keyCode),
            toggleShortcut.carbonModifiers,
            hotKeyID,
            target,
            0,
            &carbonHotKey
        )
        guard registerStatus == noErr else {
            throw ShortcutError.registrationFailed("RegisterEventHotKey failed with status \(registerStatus).")
        }
    }

    private func fourCharCode(_ value: String) -> OSType {
        value.utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }
}
