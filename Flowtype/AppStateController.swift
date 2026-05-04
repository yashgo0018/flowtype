import Foundation
import SwiftData

enum DictationState: Equatable {
    case idle(String)
    case recording(mode: RecordingMode, startedAt: Date)
    case processing
    case pasting
    case cancelled
    case error(String)

    var statusText: String {
        switch self {
        case .idle(let message):
            message
        case .recording:
            "Recording"
        case .processing:
            "Transcribing..."
        case .pasting:
            "Pasting..."
        case .cancelled:
            "Cancelled"
        case .error(let message):
            message
        }
    }
}

enum RecordingMode: Equatable {
    case toggle
    case hold
}

@MainActor
final class AppStateController: ObservableObject {
    @Published private(set) var state: DictationState = .idle("Ready")
    @Published var settings: AppSettings
    @Published var permissionsMessage: String = ""
    @Published private(set) var modelStatus: TranscriptionModelStatus
    @Published private(set) var isDownloadingModel = false
    @Published private(set) var modelDownloadMessage = ""

    private let settingsStore: SettingsStore
    private let audio: AudioCapturing
    private let transcriber: Transcribing
    private let pasteService: Pasting
    private var localStore: LocalStore?
    private let hotKeys: HotKeyService
    private var pendingPasteTarget: PasteTarget?

    init(
        settingsStore: SettingsStore = SettingsStore(),
        audio: AudioCapturing = AudioCaptureService(),
        transcriber: Transcribing = DefaultTranscriptionService(),
        pasteService: Pasting = PasteService(),
        localStore: LocalStore? = nil,
        hotKeys: HotKeyService = HotKeyService()
    ) {
        let loadedSettings = settingsStore.load()
        self.settingsStore = settingsStore
        self.settings = loadedSettings
        self.audio = audio
        self.transcriber = transcriber
        self.modelStatus = transcriber.modelStatus(settings: loadedSettings)
        self.pasteService = pasteService
        self.localStore = localStore
        self.hotKeys = hotKeys
        configureHotKeys()
    }

    @discardableResult
    func configureHotKeys() -> Bool {
        hotKeys.onToggle = { [weak self] in
            Task { @MainActor in self?.toggleRecording() }
        }
        hotKeys.onHoldStart = { [weak self] in
            Task { @MainActor in self?.holdStart() }
        }
        hotKeys.onHoldStop = { [weak self] in
            Task { @MainActor in self?.holdStop() }
        }
        hotKeys.onCancel = { [weak self] in
            Task { @MainActor in self?.cancelRecording() }
        }
        do {
            try hotKeys.start(settings: settings)
            return true
        } catch {
            state = .error(error.localizedDescription)
            return false
        }
    }

    func attachLocalStore(_ store: LocalStore) {
        localStore = store
    }

    func saveSettings(_ newSettings: AppSettings) {
        let conflicts = ShortcutParser.conflicts([
            "Hands-free toggle": newSettings.toggleShortcut,
            "Push-to-talk": newSettings.holdShortcut,
            "Cancel": newSettings.cancelShortcut,
            "Paste last": newSettings.pasteLastShortcut,
            "Open Scratchpad": newSettings.scratchpadShortcut,
            "Command Mode": newSettings.commandModeShortcut
        ])
        guard conflicts.isEmpty else {
            state = .error(conflicts.joined(separator: "\n"))
            return
        }
        settings = newSettings
        settingsStore.save(newSettings)
        let hotKeysConfigured = configureHotKeys()
        refreshModelStatus()
        guard hotKeysConfigured else { return }
        state = .idle("Settings saved")
    }

    func refreshModelStatus(for settingsOverride: AppSettings? = nil) {
        let targetSettings = settingsOverride ?? settings
        modelStatus = transcriber.modelStatus(settings: targetSettings)
        switch targetSettings.transcriptionProvider {
        case .local:
            modelDownloadMessage = modelStatus.isDownloaded
                ? "Model is downloaded and ready."
                : "Model is not downloaded yet. It will download automatically on the next dictation."
        case .groq:
            modelDownloadMessage = modelStatus.isDownloaded
                ? "Groq is configured and ready."
                : "Groq is selected. Add a Groq API key before dictating."
        }
    }

    func downloadModel(for targetSettings: AppSettings) {
        guard !isDownloadingModel else { return }
        guard targetSettings.transcriptionProvider == .local else {
            refreshModelStatus(for: targetSettings)
            return
        }
        isDownloadingModel = true
        modelDownloadMessage = "Downloading model..."
        Task {
            do {
                let status = try await transcriber.downloadModel(settings: targetSettings)
                modelStatus = status
                modelDownloadMessage = status.isDownloaded
                    ? "Model downloaded and ready."
                    : "Download finished, but the local model files could not be verified."
            } catch {
                modelDownloadMessage = "Model download failed: \(error.localizedDescription)"
            }
            isDownloadingModel = false
        }
    }

    func checkPermissions() {
        let accessibility = PermissionService.hasAccessibilityPermission(prompt: false)
        let microphone = PermissionService.microphoneAuthorizationStatus()
        if !accessibility {
            permissionsMessage = "Accessibility permission is required for paste automation and fallback shortcut monitoring."
            state = .idle("Grant Accessibility")
        } else if microphone == .denied || microphone == .restricted {
            permissionsMessage = "Microphone permission is required for recording."
            state = .idle("Grant Microphone")
        } else {
            permissionsMessage = ""
            if case .idle = state {
                state = .idle("Ready")
            }
        }
    }

    func promptForMissingStartupPermissions() {
        checkPermissions()
    }

    func requestPermissions() {
        if !PermissionService.hasAccessibilityPermission(prompt: false) {
            _ = PermissionService.hasAccessibilityPermission(prompt: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if !PermissionService.hasAccessibilityPermission(prompt: false) {
                    PermissionService.openAccessibilitySettings()
                }
                self.checkPermissions()
            }
        }
        Task {
            _ = await PermissionService.requestMicrophoneAccess()
            await MainActor.run { self.checkPermissions() }
        }
    }

    func toggleRecording() {
        if audio.isRecording {
            stopRecording()
        } else {
            startRecording(mode: .toggle)
        }
    }

    func preparePasteTargetForFlowBarInteraction() {
        guard !audio.isRecording else { return }
        pendingPasteTarget = pasteService.capturePasteTarget()
    }

    func holdStart() {
        guard !audio.isRecording else { return }
        startRecording(mode: .hold)
    }

    func holdStop() {
        guard audio.isRecording else { return }
        stopRecording()
    }

    func startRecording(mode: RecordingMode) {
        guard !audio.isRecording else { return }
        if pendingPasteTarget == nil {
            pendingPasteTarget = pasteService.capturePasteTarget()
        }
        let microphone = PermissionService.microphoneAuthorizationStatus()
        if microphone == .notDetermined {
            state = .idle("Grant Microphone")
            Task {
                let granted = await PermissionService.requestMicrophoneAccess()
                await MainActor.run {
                    if granted {
                        self.startRecording(mode: mode)
                    } else {
                        self.checkPermissions()
                    }
                }
            }
            return
        }
        guard microphone != .denied && microphone != .restricted else {
            checkPermissions()
            return
        }

        if !PermissionService.hasAccessibilityPermission(prompt: false) {
            permissionsMessage = "Accessibility permission is required to paste into the focused app. Recording will still work and leave text on the clipboard."
        } else {
            permissionsMessage = ""
        }

        do {
            try audio.start()
            state = .recording(mode: mode, startedAt: .now)
        } catch {
            state = .error("Mic error: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        do {
            guard let captured = try audio.stop() else {
                state = .idle("No speech detected")
                pendingPasteTarget = nil
                return
            }
            state = .processing
            Task {
                await transcribeAndPaste(captured)
            }
        } catch {
            state = .error("Recording failed: \(error.localizedDescription)")
        }
    }

    func cancelRecording() {
        guard audio.isRecording else { return }
        audio.cancel()
        pendingPasteTarget = nil
        state = .cancelled
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.state = .idle("Ready")
        }
    }

    private func transcribeAndPaste(_ captured: CapturedAudio) async {
        defer {
            removeCapturedAudioFile(captured.url)
        }

        do {
            let transcript = try await transcriber.transcribe(audioURL: captured.url, settings: settings)
            state = .pasting
            let target = pendingPasteTarget
            pendingPasteTarget = nil
            let outcome = pasteService.paste(
                transcript,
                restoreClipboard: settings.restoreClipboardAfterPaste,
                target: target
            )
            let historyMessage = saveTranscript(transcript, outcome: outcome)
            state = .idle(historyMessage ?? outcome.message)
        } catch {
            pendingPasteTarget = nil
            state = .error("Transcription failed: \(error.localizedDescription)")
        }
    }

    private func saveTranscript(_ transcript: String, outcome: PasteOutcome) -> String? {
        guard let localStore else {
            NSLog("Flowtype transcript history skipped: local store is not attached.")
            return nil
        }

        do {
            try localStore.saveTranscript(
                transcript,
                pasted: outcome.pasted,
                statusMessage: outcome.message,
                retentionPolicy: settings.retentionPolicy
            )
            return nil
        } catch {
            NSLog("Flowtype transcript history save failed: \(error.localizedDescription)")
            return "\(outcome.message) History could not be saved."
        }
    }

    private func removeCapturedAudioFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            NSLog("Flowtype captured audio cleanup failed for \(url.path): \(error.localizedDescription)")
        }
    }
}
