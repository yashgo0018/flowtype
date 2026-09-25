import AppKit
import Combine
import Foundation

enum RecordingMode: Equatable {
    case handsFree
    case pushToTalk
}

struct Feedback: Equatable {
    enum Kind: Equatable {
        case success
        case info
        case warning
        case error
    }

    enum Action: Equatable {
        case openHub(HubPage)
        case openAccessibilitySettings
        case openMicrophoneSettings
    }

    let kind: Kind
    let title: String
    var detail: String?
    var action: Action?
    let id = UUID()
}

enum DictationPhase: Equatable {
    case idle
    case recording(mode: RecordingMode, startedAt: Date)
    case transcribing
    case finished(Feedback)

    var isBusy: Bool {
        switch self {
        case .recording, .transcribing: true
        case .idle, .finished: false
        }
    }

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

enum ModelActivity: Equatable {
    case downloading(Double)
    case loading
}

enum HubPage: String, CaseIterable, Identifiable, Hashable {
    case home
    case history
    case dictionary
    case snippets
    case notes
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .history: "History"
        case .dictionary: "Dictionary"
        case .snippets: "Snippets"
        case .notes: "Notes"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .history: "clock.arrow.circlepath"
        case .dictionary: "character.book.closed"
        case .snippets: "text.badge.plus"
        case .notes: "note.text"
        case .settings: "gearshape"
        }
    }
}

/// Recent microphone levels for the Flow Bar waveform. Kept separate from the controller so
/// 30+ updates per second don't re-render the Hub.
@MainActor
final class AudioLevelMeter: ObservableObject {
    static let barCount = 24
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: barCount)

    func push(_ level: Float) {
        var next = levels
        next.removeFirst()
        // Light smoothing so bars move fluidly rather than flicker.
        next.append(level * 0.75 + (levels.last ?? 0) * 0.25)
        levels = next
    }

    func reset() {
        levels = Array(repeating: 0, count: Self.barCount)
    }
}

@MainActor
final class AppStateController: ObservableObject {
    @Published private(set) var phase: DictationPhase = .idle {
        didSet { hotKeys.setCancelEnabled(phase.isBusy) }
    }
    @Published private(set) var settings: AppSettings
    @Published private(set) var permissions: PermissionStatus
    @Published private(set) var modelStatus: TranscriptionModelStatus
    @Published private(set) var modelActivity: ModelActivity?
    @Published private(set) var modelError: String?
    @Published private(set) var shortcutWarning: String?
    @Published private(set) var lastTranscript: String?
    @Published var hubPage: HubPage = .home

    let levelMeter = AudioLevelMeter()
    /// Asks the app to show the Hub window.
    var onShowHub: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?

    private let settingsStore: SettingsStore
    private let audio: AudioCapturing
    private let transcriber: Transcribing
    private let pasteService: Pasting
    private let hotKeys: HotKeyService
    private let appleSpeechSupported: Bool
    private let currentPermissions: @MainActor () -> PermissionStatus
    private var localStore: LocalStore?

    private var pasteTarget: PasteTarget?
    private var sessionID = UUID()
    private var transcriptionTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    /// Model preparation is tracked per engine and Whisper variant, so switching models never shows
    /// (or waits behind) another model's loading or error. See `modelKey(for:)`.
    private var preparations: [String: Task<Void, Never>] = [:]
    private var activities: [String: ModelActivity] = [:]
    private var errors: [String: String] = [:]
    private var toggleHeldSince: Date?
    private var maintenanceTimers: [Timer] = []
    private var lastDictationAt = Date()
    /// The on-device model uses 0.5–1.5 GB of memory; release it after this long without dictating.
    static let modelIdleUnloadInterval: TimeInterval = 20 * 60

    init(
        settingsStore: SettingsStore = SettingsStore(),
        audio: AudioCapturing = AudioRecorder(),
        transcriber: Transcribing = DefaultTranscriptionService(),
        pasteService: Pasting = PasteService(),
        hotKeys: HotKeyService = HotKeyService(),
        appleSpeechSupported: Bool = AppleSpeech.isSupported,
        permissions: @escaping @MainActor () -> PermissionStatus = { PermissionStatus.current() }
    ) {
        let loadedSettings = settingsStore.load()
        self.settingsStore = settingsStore
        self.settings = loadedSettings
        self.audio = audio
        self.transcriber = transcriber
        self.pasteService = pasteService
        self.hotKeys = hotKeys
        self.appleSpeechSupported = appleSpeechSupported
        self.currentPermissions = permissions
        self.permissions = permissions()
        self.modelStatus = transcriber.modelStatus(settings: loadedSettings)
    }

    /// Something must be fixed before dictation can paste: a permission or a missing API key.
    var needsSetup: Bool {
        permissions.microphone == .denied || permissions.microphone == .restricted
            || !permissions.accessibility
            || (settings.transcriptionProvider == .groq && !settings.hasGroqAPIKey)
    }

    // MARK: - Lifecycle

    func start(localStore: LocalStore) {
        self.localStore = localStore
        lastTranscript = localStore.latestTranscript()
        try? localStore.applyRetention(settings.retentionPolicy)

        audio.onLevel = { [weak self] level in
            self?.levelMeter.push(level)
        }
        audio.onInterruption = { [weak self] in
            // The input device changed (e.g. AirPods disconnected): keep what was said so far.
            self?.stopRecording()
        }
        wireHotKeys()
        do {
            shortcutWarning = try hotKeys.configure(settings: settings)
        } catch {
            shortcutWarning = error.localizedDescription
        }

        let permissionTimer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
        let housekeepingTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.performHousekeeping() }
        }
        for timer in [permissionTimer, housekeepingTimer] {
            RunLoop.main.add(timer, forMode: .common)
        }
        maintenanceTimers = [permissionTimer, housekeepingTimer]

        adoptAppleSpeechIfUseful()

        // Load an already-downloaded model in the background so the first dictation is fast.
        if usesOnDeviceModel, modelStatus.isReady {
            prepareModel()
        }
    }

    private var usesOnDeviceModel: Bool {
        settings.transcriptionProvider != .groq
    }

    /// One-time switch to Apple's built-in model for people who never downloaded a Whisper model,
    /// so they don't need a download at all. Anyone who already has Whisper keeps it.
    func adoptAppleSpeechIfUseful() {
        guard !settingsStore.appleSpeechMigrationDone else { return }
        settingsStore.appleSpeechMigrationDone = true
        guard appleSpeechSupported, settings.transcriptionProvider == .local else { return }
        var whisper = settings
        whisper.transcriptionProvider = .local
        guard !transcriber.modelStatus(settings: whisper).isReady else { return }
        Log.dictation.info("Switching to Apple speech recognition; no Whisper model was downloaded")
        updateSettings { $0.transcriptionProvider = .apple }
    }

    /// Runs every minute: enforces history retention and frees the model when idle.
    func performHousekeeping(now: Date = .now) {
        try? localStore?.applyRetention(settings.retentionPolicy)
        if !phase.isBusy,
           preparations.isEmpty,
           now.timeIntervalSince(lastDictationAt) > Self.modelIdleUnloadInterval,
           transcriber.isLoaded(settings: settings) {
            transcriber.unloadModel()
            Log.dictation.info("Unloaded the speech model after being idle")
        }
    }

    private func wireHotKeys() {
        hotKeys.onTogglePressed = { [weak self] in self?.handleTogglePressed() }
        hotKeys.onToggleReleased = { [weak self] in self?.handleToggleReleased() }
        hotKeys.onHoldDown = { [weak self] in self?.handleHoldDown() }
        hotKeys.onHoldUp = { [weak self] in self?.handleHoldUp() }
        hotKeys.onHoldInterrupted = { [weak self] in self?.handleHoldInterrupted() }
        hotKeys.onCancel = { [weak self] in self?.cancel() }
        hotKeys.onPasteLast = { [weak self] in self?.pasteLastTranscript() }
    }

    // MARK: - Shortcut handling

    func handleTogglePressed() {
        switch phase {
        case .recording:
            toggleHeldSince = nil
            stopRecording()
        case .transcribing:
            break
        case .idle, .finished:
            if startRecording(mode: .handsFree) {
                toggleHeldSince = .now
            }
        }
    }

    /// Holding the hands-free shortcut works as push-to-talk: releasing it after a long press stops.
    func handleToggleReleased() {
        guard let heldSince = toggleHeldSince else { return }
        toggleHeldSince = nil
        if phase.isRecording, Date().timeIntervalSince(heldSince) >= 0.6 {
            stopRecording()
        }
    }

    func handleHoldDown() {
        switch phase {
        case .idle, .finished:
            startRecording(mode: .pushToTalk)
        case .recording, .transcribing:
            break
        }
    }

    func handleHoldUp() {
        guard case .recording(.pushToTalk, let startedAt) = phase else { return }
        if Date().timeIntervalSince(startedAt) < 0.3 {
            // A quick tap of the hold key is not a dictation.
            discardRecording()
        } else {
            stopRecording()
        }
    }

    func handleHoldInterrupted() {
        guard case .recording(.pushToTalk, let startedAt) = phase else { return }
        // The hold key was part of a key combo (Fn+←, Fn+F5…), not push-to-talk.
        if Date().timeIntervalSince(startedAt) < 1.5 {
            discardRecording()
        }
    }

    // MARK: - Recording

    /// Flow Bar button: start, or stop when already recording.
    func toggleFromFlowBar() {
        switch phase {
        case .recording: stopRecording()
        case .transcribing: break
        case .idle, .finished: startRecording(mode: .handsFree)
        }
    }

    @discardableResult
    func startRecording(mode: RecordingMode) -> Bool {
        guard !phase.isBusy else { return false }
        refreshPermissions()

        switch permissions.microphone {
        case .authorized:
            break
        case .notDetermined:
            Task {
                let granted = await PermissionService.requestMicrophoneAccess()
                refreshPermissions()
                if granted {
                    showFeedback(Feedback(kind: .info, title: "Microphone ready", detail: "Start dictating again."))
                }
            }
            return false
        default:
            showFeedback(Feedback(
                kind: .error,
                title: "Microphone access is off",
                detail: "Allow Flowtype in Privacy & Security → Microphone.",
                action: .openMicrophoneSettings
            ), duration: 6)
            return false
        }

        if settings.transcriptionProvider == .groq, !settings.hasGroqAPIKey {
            showFeedback(Feedback(
                kind: .error,
                title: "Groq API key missing",
                detail: "Add one in Settings or switch to on-device.",
                action: .openHub(.settings)
            ), duration: 6)
            return false
        }

        let target = pasteService.captureTarget()
        if target?.isSecureField == true {
            showFeedback(Feedback(kind: .info, title: "Password field", detail: "Dictation is off in password fields."), duration: 2.5)
            return false
        }
        pasteTarget = target
        levelMeter.reset()
        do {
            try audio.start(deviceUID: settings.microphoneUID.isEmpty ? nil : settings.microphoneUID)
        } catch {
            pasteTarget = nil
            showFeedback(Feedback(kind: .error, title: "Couldn't start the microphone", detail: error.localizedDescription), duration: 5)
            return false
        }

        feedbackTask?.cancel()
        sessionID = UUID()
        lastDictationAt = .now
        phase = .recording(mode: mode, startedAt: .now)
        if settings.playSounds {
            SoundEffects.play(.start)
        }
        // Load the model while the user speaks rather than after they finish.
        if usesOnDeviceModel, !transcriber.isLoaded(settings: settings) {
            prepareModel()
        }
        return true
    }

    func stopRecording() {
        guard phase.isRecording else { return }
        toggleHeldSince = nil
        guard let recorded = audio.stop() else {
            phase = .idle
            return
        }
        if settings.playSounds {
            SoundEffects.play(.stop)
        }

        guard recorded.duration >= 0.3 else {
            pasteTarget = nil
            phase = .idle
            return
        }
        guard recorded.peakLevel >= 0.001 else {
            pasteTarget = nil
            showFeedback(Feedback(
                kind: .warning,
                title: "No sound from the microphone",
                detail: "Check the input device in Settings.",
                action: .openHub(.settings)
            ), duration: 5)
            return
        }

        let target = pasteTarget
        pasteTarget = nil
        let session = sessionID
        let settings = settings
        let rules = localStore?.replacementRules() ?? TextReplacementRules()
        phase = .transcribing
        transcriptionTask = Task { [weak self] in
            await self?.transcribeAndInsert(recorded, target: target, settings: settings, rules: rules, session: session)
        }
    }

    /// Stops without transcribing.
    private func discardRecording() {
        guard phase.isRecording else { return }
        audio.cancel()
        pasteTarget = nil
        toggleHeldSince = nil
        phase = .idle
    }

    func cancel() {
        switch phase {
        case .recording:
            audio.cancel()
            pasteTarget = nil
        case .transcribing:
            transcriptionTask?.cancel()
        case .idle, .finished:
            return
        }
        toggleHeldSince = nil
        sessionID = UUID()
        if settings.playSounds {
            SoundEffects.play(.cancel)
        }
        showFeedback(Feedback(kind: .info, title: "Cancelled"), duration: 1.2)
    }

    private func transcribeAndInsert(
        _ recorded: RecordedAudio,
        target: PasteTarget?,
        settings: AppSettings,
        rules: TextReplacementRules,
        session: UUID
    ) async {
        do {
            let raw = try await transcriber.transcribe(recorded, settings: settings, vocabulary: rules.promptTerms)
            guard session == sessionID, !Task.isCancelled else { return }

            let result = TranscriptPostProcessor.process(raw, rules: rules)
            guard !result.text.isEmpty else {
                showFeedback(Feedback(kind: .info, title: "Didn't catch that", detail: "No speech was detected."), duration: 2.5)
                return
            }

            let outcome = await pasteService.insert(result.text, into: target, restoreClipboard: settings.restoreClipboardAfterPaste)
            if outcome == .blockedSecureField {
                // Possibly a spoken password: don't keep it anywhere.
                showFeedback(Feedback(kind: .info, title: "Password field", detail: "Dictation is off in password fields."), duration: 2.5)
                return
            }
            lastTranscript = result.text
            Log.dictation.info("Dictation of \(recorded.duration, format: .fixed(precision: 1))s finished: \(outcome.message, privacy: .public)")
            saveHistory(result.text, outcome: outcome, duration: recorded.duration, settings: settings)
            localStore?.recordDictionaryUsage(phrases: result.matchedPhrases)
            guard session == sessionID else { return }

            switch outcome {
            case .pasted:
                let words = TextMetrics.wordCount(result.text)
                showFeedback(Feedback(kind: .success, title: "Pasted", detail: "\(words) word\(words == 1 ? "" : "s")"), duration: 1.6)
            case .copied(.needsAccessibility):
                showFeedback(Feedback(
                    kind: .warning,
                    title: "Copied — press ⌘V",
                    detail: "Allow Accessibility to paste automatically.",
                    action: .openHub(.home)
                ), duration: 5)
            case .copied:
                showFeedback(Feedback(kind: .info, title: "Copied — press ⌘V", detail: "No text field was focused."), duration: 3.5)
            case .blockedSecureField:
                break
            }
        } catch is CancellationError {
            return
        } catch {
            Log.dictation.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            guard session == sessionID, !Task.isCancelled else { return }
            if settings.playSounds {
                SoundEffects.play(.error)
            }
            showFeedback(Feedback(kind: .error, title: "Transcription failed", detail: error.localizedDescription, action: .openHub(.settings)), duration: 6)
        }
    }

    private func saveHistory(_ text: String, outcome: PasteOutcome, duration: TimeInterval, settings: AppSettings) {
        do {
            try localStore?.saveTranscript(
                text,
                pasted: outcome.pasted,
                statusMessage: outcome.message,
                durationSeconds: duration,
                retentionPolicy: settings.retentionPolicy
            )
        } catch {
            Log.data.error("Could not save history: \(error.localizedDescription, privacy: .public)")
        }
    }

    func pasteLastTranscript() {
        guard !phase.isBusy else { return }
        guard let text = lastTranscript ?? localStore?.latestTranscript() else {
            showFeedback(Feedback(kind: .info, title: "Nothing to paste yet"), duration: 2)
            return
        }
        paste(text)
    }

    /// Pastes arbitrary text (e.g. from History) into the app that was last in front.
    func paste(_ text: String) {
        Task {
            // Let the shortcut's modifier keys come up first.
            try? await Task.sleep(for: .milliseconds(120))
            let outcome = await pasteService.insert(text, into: nil, restoreClipboard: settings.restoreClipboardAfterPaste)
            let title = switch outcome {
            case .pasted: "Pasted"
            case .copied: "Copied — press ⌘V"
            case .blockedSecureField: "Not typed into a password field"
            }
            showFeedback(Feedback(kind: outcome.pasted ? .success : .info, title: title), duration: 1.6)
        }
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    #if DEBUG
    /// Puts the dictation bar into a given state for rendering website screenshots.
    func setPhaseForScreenshots(_ phase: DictationPhase) {
        self.phase = phase
    }
    #endif

    // MARK: - Feedback

    func showFeedback(_ feedback: Feedback, duration: TimeInterval = 2.5) {
        feedbackTask?.cancel()
        phase = .finished(feedback)
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self, case .finished(let current) = self.phase, current.id == feedback.id else { return }
            self.phase = .idle
        }
    }

    func perform(_ action: Feedback.Action) {
        switch action {
        case .openHub(let page):
            showHub(page)
        case .openAccessibilitySettings:
            PermissionService.openAccessibilitySettings()
        case .openMicrophoneSettings:
            PermissionService.openMicrophoneSettings()
        }
        if case .finished = phase {
            phase = .idle
        }
    }

    func showHub(_ page: HubPage? = nil) {
        if let page {
            hubPage = page
        }
        onShowHub?()
    }

    // MARK: - Permissions

    func refreshPermissions() {
        let current = currentPermissions()
        guard current != permissions else { return }
        let gainedAccessibility = current.accessibility && !permissions.accessibility
        permissions = current
        if gainedAccessibility {
            hotKeys.restartMonitors()
        }
    }

    func requestMicrophoneAccess() {
        switch permissions.microphone {
        case .notDetermined:
            Task {
                _ = await PermissionService.requestMicrophoneAccess()
                refreshPermissions()
            }
        default:
            PermissionService.openMicrophoneSettings()
        }
    }

    func requestAccessibilityAccess() {
        if !PermissionService.hasAccessibilityPermission(prompt: true) {
            PermissionService.openAccessibilitySettings()
        }
        refreshPermissions()
    }

    /// For when System Settings shows Flowtype as allowed but macOS still reports it untrusted
    /// (common after the app is updated or rebuilt).
    func resetAccessibilityAccess() {
        PermissionService.resetAccessibilityPermission()
        requestAccessibilityAccess()
    }

    // MARK: - Settings

    /// Applies a settings change immediately. Returns an error message if it was rejected.
    @discardableResult
    func updateSettings(_ change: (inout AppSettings) -> Void) -> String? {
        var next = settings
        change(&next)
        guard next != settings else { return nil }

        let conflicts = ShortcutParser.conflicts(next.shortcutBindings)
        guard conflicts.isEmpty else { return conflicts.joined(separator: "\n") }

        let shortcutsChanged = next.toggleShortcut != settings.toggleShortcut
            || next.pasteLastShortcut != settings.pasteLastShortcut
            || next.holdKey != settings.holdKey
        if shortcutsChanged {
            do {
                shortcutWarning = try hotKeys.configure(settings: next)
            } catch {
                shortcutWarning = try? hotKeys.configure(settings: settings)
                return error.localizedDescription
            }
        }

        let modelChanged = next.transcriptionProvider != settings.transcriptionProvider
            || next.transcriptionModel != settings.transcriptionModel
            || next.groqAPIKey != settings.groqAPIKey
        let retentionChanged = next.retentionPolicy != settings.retentionPolicy

        let previous = settings
        settings = next
        settingsStore.save(next)

        if modelChanged {
            // Nothing needs Whisper after switching to another engine, so free its memory right away.
            if previous.transcriptionProvider == .local, next.transcriptionProvider != .local {
                transcriber.unloadWhisperModel()
            }
            // Selecting a model again clears its old error, so it gets a fresh attempt.
            errors[modelKey(for: next)] = nil
            publishModelState()
            refreshModelStatus()
            if usesOnDeviceModel, modelStatus.isReady, !transcriber.isLoaded(settings: next) {
                prepareModel()
            }
        }
        if retentionChanged {
            try? localStore?.applyRetention(next.retentionPolicy)
        }
        return nil
    }

    func suspendShortcuts() {
        hotKeys.suspend()
    }

    func resumeShortcuts() {
        hotKeys.resume()
    }

    // MARK: - Model

    func refreshModelStatus() {
        modelStatus = transcriber.modelStatus(settings: settings)
    }

    /// What a model preparation is for: each engine, and each Whisper variant, prepares independently.
    private func modelKey(for settings: AppSettings) -> String {
        settings.transcriptionProvider == .local
            ? "whisper:\(settings.transcriptionModel)"
            : settings.transcriptionProvider.rawValue
    }

    /// Shows the loading state and error of the *selected* model only.
    private func publishModelState() {
        let key = modelKey(for: settings)
        if modelActivity != activities[key] { modelActivity = activities[key] }
        if modelError != errors[key] { modelError = errors[key] }
    }

    /// Downloads (if needed) and loads the selected on-device model.
    func prepareModel() {
        guard usesOnDeviceModel else { return }
        let target = settings
        let key = modelKey(for: target)
        guard preparations[key] == nil else { return }
        errors[key] = nil
        activities[key] = modelStatus.isReady ? .loading : .downloading(0)
        publishModelState()
        preparations[key] = Task { [weak self] in
            guard let self else { return }
            do {
                try await transcriber.prepare(settings: target) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.preparations[key] != nil else { return }
                        self.activities[key] = fraction.map { .downloading($0) } ?? .loading
                        self.publishModelState()
                    }
                }
            } catch {
                Log.dictation.error("Model preparation failed: \(error.localizedDescription, privacy: .public)")
                errors[key] = "Couldn't prepare the speech model: \(error.localizedDescription)"
            }
            preparations[key] = nil
            activities[key] = nil
            publishModelState()
            refreshModelStatus()
        }
    }

    func deleteDownloadedModels() {
        do {
            try transcriber.deleteDownloadedModels()
        } catch {
            errors[modelKey(for: settings)] = error.localizedDescription
            publishModelState()
        }
        refreshModelStatus()
    }

    // MARK: - Data

    func deleteAllHistory() {
        do {
            try localStore?.deleteAllHistory()
            lastTranscript = nil
        } catch {
            Log.data.error("Could not delete history: \(error.localizedDescription, privacy: .public)")
        }
    }
}
