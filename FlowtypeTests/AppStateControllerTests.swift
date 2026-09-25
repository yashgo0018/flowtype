import AVFoundation
import XCTest
@testable import Flowtype

@MainActor
final class AppStateControllerTests: XCTestCase {
    private var audio: FakeAudio!
    private var transcriber: FakeTranscriber!
    private var paste: FakePaste!
    private var permissions = PermissionStatus(microphone: .authorized, accessibility: true)
    private var suiteName = ""

    override func setUp() async throws {
        audio = FakeAudio()
        transcriber = FakeTranscriber()
        paste = FakePaste()
        permissions = PermissionStatus(microphone: .authorized, accessibility: true)
        suiteName = "AppStateControllerTests-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func makeController(
        appleSpeechSupported: Bool = true,
        configure: (inout AppSettings) -> Void = { _ in }
    ) -> AppStateController {
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = SettingsStore(defaults: defaults, apiKeyStore: UserDefaultsGroqAPIKeyStore(defaults: defaults))
        var settings = store.load()
        settings.playSounds = false
        configure(&settings)
        store.save(settings)
        return AppStateController(
            settingsStore: store,
            audio: audio,
            transcriber: transcriber,
            pasteService: paste,
            appleSpeechSupported: appleSpeechSupported,
            permissions: { [unowned self] in self.permissions }
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func isFinished(_ controller: AppStateController, kind: Feedback.Kind) -> Bool {
        if case .finished(let feedback) = controller.phase { return feedback.kind == kind }
        return false
    }

    // MARK: - Happy path

    func testDictationIsTranscribedCleanedAndPasted() async {
        transcriber.result = "<|startoftranscript|><|en|> Hello world.<|endoftext|>"
        let controller = makeController()

        XCTAssertTrue(controller.startRecording(mode: .handsFree))
        XCTAssertTrue(controller.phase.isRecording)
        XCTAssertTrue(audio.isRecording)

        controller.stopRecording()
        XCTAssertEqual(controller.phase, .transcribing)

        await waitUntil { !self.paste.inserted.isEmpty }
        XCTAssertEqual(paste.inserted, ["Hello world."])
        XCTAssertEqual(controller.lastTranscript, "Hello world.")
        XCTAssertTrue(isFinished(controller, kind: .success))
    }

    func testEmptyTranscriptIsNotPasted() async {
        transcriber.result = "[BLANK_AUDIO]"
        let controller = makeController()
        controller.startRecording(mode: .handsFree)
        controller.stopRecording()

        await waitUntil { self.isFinished(controller, kind: .info) }
        XCTAssertTrue(paste.inserted.isEmpty)
        XCTAssertNil(controller.lastTranscript)
    }

    // MARK: - Recordings that shouldn't be transcribed

    func testVeryShortRecordingIsDiscardedSilently() {
        audio.duration = 0.1
        let controller = makeController()
        controller.startRecording(mode: .handsFree)
        controller.stopRecording()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(transcriber.calls, 0)
    }

    func testSilentMicrophoneWarns() {
        audio.peak = 0
        let controller = makeController()
        controller.startRecording(mode: .handsFree)
        controller.stopRecording()

        XCTAssertTrue(isFinished(controller, kind: .warning))
        XCTAssertEqual(transcriber.calls, 0)
    }

    // MARK: - Cancellation

    func testCancelWhileRecordingDiscardsAudio() {
        let controller = makeController()
        controller.startRecording(mode: .handsFree)
        controller.cancel()

        XCTAssertFalse(audio.isRecording)
        XCTAssertEqual(audio.cancelCount, 1)
        XCTAssertEqual(transcriber.calls, 0)
    }

    func testCancelDuringTranscriptionNeverPastes() async {
        transcriber.delay = .milliseconds(200)
        let controller = makeController()
        controller.startRecording(mode: .handsFree)
        controller.stopRecording()
        controller.cancel()

        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(paste.inserted.isEmpty)
        XCTAssertNil(controller.lastTranscript)
    }

    func testNewDictationIgnoresLateResultFromCancelledOne() async {
        transcriber.delay = .milliseconds(200)
        transcriber.result = "first"
        let controller = makeController()
        controller.startRecording(mode: .handsFree)
        controller.stopRecording()
        controller.cancel()

        transcriber.delay = .zero
        transcriber.result = "second"
        controller.startRecording(mode: .handsFree)
        controller.stopRecording()

        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(paste.inserted, ["second"])
    }

    // MARK: - Push-to-talk

    func testQuickTapOfHoldKeyDoesNotDictate() {
        let controller = makeController()
        controller.handleHoldDown()
        XCTAssertTrue(controller.phase.isRecording)

        controller.handleHoldUp()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(audio.cancelCount, 1)
        XCTAssertEqual(transcriber.calls, 0)
    }

    func testHoldKeyUsedInKeyComboIsDiscarded() {
        let controller = makeController()
        controller.handleHoldDown()
        controller.handleHoldInterrupted()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(transcriber.calls, 0)
    }

    func testHoldKeyIsIgnoredDuringHandsFreeDictation() {
        let controller = makeController()
        controller.handleTogglePressed()
        controller.handleToggleReleased()
        guard case .recording(.handsFree, _) = controller.phase else {
            return XCTFail("Expected hands-free recording")
        }

        controller.handleHoldDown()
        controller.handleHoldUp()
        XCTAssertTrue(controller.phase.isRecording)
    }

    // MARK: - Refusals

    func testPasswordFieldRefusesToStart() {
        paste.secureTarget = true
        let controller = makeController()

        XCTAssertFalse(controller.startRecording(mode: .handsFree))
        XCTAssertFalse(audio.isRecording)
    }

    func testTranscriptBlockedByPasswordFieldIsNotKept() async {
        paste.outcome = .blockedSecureField
        let controller = makeController()
        controller.startRecording(mode: .handsFree)
        controller.stopRecording()

        await waitUntil { self.isFinished(controller, kind: .info) }
        XCTAssertNil(controller.lastTranscript)
    }

    func testDeniedMicrophoneShowsError() {
        permissions.microphone = .denied
        let controller = makeController()

        XCTAssertFalse(controller.startRecording(mode: .handsFree))
        XCTAssertTrue(isFinished(controller, kind: .error))
    }

    func testGroqWithoutAPIKeyShowsError() {
        let controller = makeController { $0.transcriptionProvider = .groq }

        XCTAssertFalse(controller.startRecording(mode: .handsFree))
        XCTAssertTrue(isFinished(controller, kind: .error))
    }

    // MARK: - Settings and housekeeping

    func testConflictingShortcutsAreRejected() {
        let controller = makeController()
        let error = controller.updateSettings { $0.pasteLastShortcut = "control+option+space" }

        XCTAssertNotNil(error)
        XCTAssertEqual(controller.settings.pasteLastShortcut, AppSettings.defaults.pasteLastShortcut)
    }

    // MARK: - Apple speech default

    func testSwitchesToAppleSpeechWhenNoWhisperModelWasDownloaded() {
        transcriber.whisperReady = false
        let controller = makeController { $0.transcriptionProvider = .local }

        controller.adoptAppleSpeechIfUseful()

        XCTAssertEqual(controller.settings.transcriptionProvider, .apple)
    }

    func testKeepsWhisperWhenItsModelIsAlreadyDownloaded() {
        transcriber.whisperReady = true
        let controller = makeController { $0.transcriptionProvider = .local }

        controller.adoptAppleSpeechIfUseful()

        XCTAssertEqual(controller.settings.transcriptionProvider, .local)
    }

    func testAppleSpeechSwitchIsOnlyConsideredOnce() {
        transcriber.whisperReady = true
        let controller = makeController { $0.transcriptionProvider = .local }
        controller.adoptAppleSpeechIfUseful()

        // Even if the Whisper model disappears later, the user's choice isn't overridden.
        transcriber.whisperReady = false
        controller.adoptAppleSpeechIfUseful()

        XCTAssertEqual(controller.settings.transcriptionProvider, .local)
    }

    func testNoSwitchOnMacsWithoutAppleSpeech() {
        transcriber.whisperReady = false
        let controller = makeController(appleSpeechSupported: false) { $0.transcriptionProvider = .local }

        controller.adoptAppleSpeechIfUseful()

        XCTAssertEqual(controller.settings.transcriptionProvider, .local)
    }

    func testSwitchingBackToAppleDoesNotWaitForASlowWhisperLoad() async {
        transcriber.whisperLoadTime = .seconds(2)
        let controller = makeController { $0.transcriptionProvider = .apple }

        controller.updateSettings { $0.transcriptionProvider = .local }
        XCTAssertEqual(controller.modelActivity, .loading, "Whisper should be loading")

        controller.updateSettings { $0.transcriptionProvider = .apple }
        await waitUntil({ controller.modelActivity == nil }, timeout: 0.5)

        XCTAssertNil(controller.modelActivity, "Apple showed Whisper's loading state")
        XCTAssertTrue(transcriber.isLoaded(settings: controller.settings), "Apple wasn't prepared while Whisper loaded")
    }

    func testLeavingWhisperFreesItsMemoryImmediately() {
        let controller = makeController { $0.transcriptionProvider = .local }

        controller.updateSettings { $0.transcriptionProvider = .apple }
        XCTAssertEqual(transcriber.whisperUnloadCount, 1)

        // Switching between engines that aren't Whisper doesn't touch it.
        controller.updateSettings { $0.transcriptionProvider = .groq }
        XCTAssertEqual(transcriber.whisperUnloadCount, 1)
    }

    func testIdleModelIsUnloadedButNotWhileDictating() {
        transcriber.loaded = true
        let controller = makeController()
        let later = Date().addingTimeInterval(AppStateController.modelIdleUnloadInterval + 60)

        controller.startRecording(mode: .handsFree)
        controller.performHousekeeping(now: later)
        XCTAssertEqual(transcriber.unloadCount, 0)

        controller.cancel()
        controller.performHousekeeping(now: later)
        XCTAssertEqual(transcriber.unloadCount, 1)
    }
}

// MARK: - Fakes

private final class FakeAudio: AudioCapturing {
    var onLevel: (@MainActor (Float) -> Void)?
    var onInterruption: (@MainActor () -> Void)?
    var duration: TimeInterval = 2
    var peak: Float = 0.5
    var cancelCount = 0
    private(set) var isRecording = false

    func start(deviceUID: String?) throws {
        isRecording = true
    }

    func stop() -> RecordedAudio? {
        guard isRecording else { return nil }
        isRecording = false
        let samples = [Float](repeating: 0, count: Int(duration * RecordedAudio.sampleRate))
        return RecordedAudio(samples: samples, peakLevel: peak)
    }

    func cancel() {
        isRecording = false
        cancelCount += 1
    }
}

@MainActor
private final class FakeTranscriber: Transcribing {
    var result = "Hello world."
    var delay: Duration = .zero
    var loaded = false
    /// Whether a Whisper model is downloaded; other engines always report ready.
    var whisperReady = true
    /// How long preparing a Whisper model takes (Apple's model prepares immediately).
    var whisperLoadTime: Duration = .zero
    private var loadedProviders: Set<TranscriptionProvider> = []
    var calls = 0
    var unloadCount = 0

    func transcribe(_ audio: RecordedAudio, settings: AppSettings, vocabulary: [String]) async throws -> String {
        calls += 1
        let output = result
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return output
    }

    func modelStatus(settings: AppSettings) -> TranscriptionModelStatus {
        TranscriptionModelStatus(
            modelName: settings.transcriptionModel,
            isReady: settings.transcriptionProvider == .local ? whisperReady : true,
            localPath: nil
        )
    }

    func prepare(settings: AppSettings, progress: ModelPreparationProgress?) async throws {
        if settings.transcriptionProvider == .local, whisperLoadTime > .zero {
            try await Task.sleep(for: whisperLoadTime)
        }
        loadedProviders.insert(settings.transcriptionProvider)
    }

    func isLoaded(settings: AppSettings) -> Bool {
        loaded || loadedProviders.contains(settings.transcriptionProvider)
    }

    func unloadModel() {
        loaded = false
        unloadCount += 1
    }

    var whisperUnloadCount = 0
    func unloadWhisperModel() {
        loadedProviders.remove(.local)
        whisperUnloadCount += 1
    }

    func deleteDownloadedModels() throws {}
}

@MainActor
private final class FakePaste: Pasting {
    var secureTarget = false
    var outcome: PasteOutcome = .pasted
    var inserted: [String] = []

    func captureTarget() -> PasteTarget? {
        PasteTarget(processIdentifier: 1, bundleIdentifier: "test.target", appName: "Target", focusedElement: nil, isSecureField: secureTarget)
    }

    func insert(_ text: String, into target: PasteTarget?, restoreClipboard: Bool) async -> PasteOutcome {
        if outcome == .pasted {
            inserted.append(text)
        }
        return outcome
    }
}
