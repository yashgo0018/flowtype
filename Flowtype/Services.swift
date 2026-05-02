import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os
@preconcurrency import WhisperKit

private let pasteLog = Logger(subsystem: "com.yashgoyal.Flowtype", category: "paste")

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
        return cleanTranscript(text)
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
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
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
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: appSupport.path, isDirectory: &isDirectory), isDirectory.boolValue else {
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
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }

        let requiredDirectories = ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"]
        let hasCompiledModels = requiredDirectories.allSatisfy { name in
            var isDirectory: ObjCBool = false
            let path = folder.appendingPathComponent(name, isDirectory: true).path
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        let hasConfig = FileManager.default.fileExists(atPath: folder.appendingPathComponent("config.json").path)
        return hasCompiledModels && hasConfig
    }

    private func cleanTranscript(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let resolvedPID = focusedPID ?? frontmostPID, resolvedPID != appPID else {
            return .unavailable
        }

        let role = focusedElement.flatMap { self.role(for: $0) }
        return .text(PasteTarget(processIdentifier: resolvedPID, focusedElement: focusedElement, role: role))
    }

    func paste(_ text: String, restoreClipboard: Bool, target: PasteTarget?) -> PasteOutcome {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return PasteOutcome(pasted: false, message: "No speech detected.")
        }

        let target = target ?? capturePasteTarget()

        let appPID = ProcessInfo.processInfo.processIdentifier
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let canSendCmdV = (target?.processIdentifier ?? frontmostPID).map { $0 != appPID } ?? false

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        guard pasteboard.setString(cleaned, forType: .string) else {
            return PasteOutcome(pasted: false, message: "Could not write transcript to clipboard.")
        }

        if canSendCmdV {
            if let target {
                Self.reactivateTarget(target)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                Self.sendCommandV()
            }

            if restoreClipboard, let previous {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    pasteboard.clearContents()
                    pasteboard.setString(previous, forType: .string)
                }
            }

            return PasteOutcome(pasted: true, message: "Pasted transcript.")
        }

        if let target, target.focusedElement != nil {
            Self.reactivateTarget(target)
            if Self.insertTextWithAccessibility(cleaned, into: target) {
                return PasteOutcome(pasted: true, message: "Inserted transcript.")
            }
        }

        return PasteOutcome(pasted: false, message: "Copied transcript to clipboard. No focused field detected.")
    }

    private static func insertTextWithAccessibility(_ text: String, into target: PasteTarget) -> Bool {
        guard let element = target.focusedElement else { return false }

        let rawValue = stringValue(for: element)
        let placeholder = placeholderValue(for: element)
        let charCount = numberOfCharacters(for: element)
        let preRange = selectedTextRange(for: element)

        pasteLog.info("ax-insert: role=\(target.role ?? "nil", privacy: .public) rawValue=\(rawValue ?? "<nil>", privacy: .public) placeholder=\(placeholder ?? "<nil>", privacy: .public) charCount=\(String(describing: charCount), privacy: .public) preRange=\(String(describing: preRange), privacy: .public)")

        let isEmpty: Bool
        if let charCount {
            isEmpty = charCount == 0
        } else if let rawValue, let placeholder, rawValue == placeholder {
            isEmpty = true
        } else {
            isEmpty = (rawValue?.isEmpty ?? true)
        }

        let baseValue: NSString
        let safeRange: NSRange

        if isEmpty {
            baseValue = ""
            safeRange = NSRange(location: 0, length: 0)
        } else {
            guard let currentValue = rawValue else { return false }
            baseValue = currentValue as NSString
            if let selectedRange = preRange, NSMaxRange(selectedRange) <= baseValue.length {
                safeRange = selectedRange
            } else {
                return false
            }
        }

        let updatedValue = baseValue.replacingCharacters(in: safeRange, with: text)
        let valueResult = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, updatedValue as CFTypeRef)
        pasteLog.info("ax-insert: isEmpty=\(isEmpty, privacy: .public) safeRange=\(NSStringFromRange(safeRange), privacy: .public) writeAX=\(valueResult.rawValue, privacy: .public)")
        guard valueResult == .success else {
            return false
        }

        let newCursorPosition = safeRange.location + (text as NSString).length
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            var cursorRange = CFRange(location: newCursorPosition, length: 0)
            if let cursorValue = AXValueCreate(.cfRange, &cursorRange) {
                let cursorResult = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, cursorValue)
                pasteLog.info("ax-insert: cursor write to \(newCursorPosition, privacy: .public) result=\(cursorResult.rawValue, privacy: .public)")
            }
        }
        return true
    }

    private static func numberOfCharacters(for element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.intValue
    }

    private static func placeholderValue(for element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPlaceholderValueAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func stringValue(for element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
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
