import AVFoundation
import CoreAudio
import SwiftData
import SwiftUI
import XCTest
@testable import Flowtype

final class MeetingQueueTests: XCTestCase {
    func testBoundedForLongMeetingAndReportsDroppedIntervals() {
        let queue = MeetingAudioQueue()
        let block = Array(repeating: Float(0.2), count: 16_000)
        // Two hours with a stalled consumer must not retain two hours of audio.
        for second in 0..<7200 {
            queue.append(block, source: .microphone, at: Double(second))
            queue.append(block, source: .system, at: Double(second))
        }
        XCTAssertLessThanOrEqual(queue.bufferedFrames, (MeetingAudioQueue.capacity + 2) * MeetingAudioQueue.chunkFrames)
        queue.finish()
        XCTAssertLessThanOrEqual(queue.bufferedFrames, MeetingAudioQueue.capacity * MeetingAudioQueue.chunkFrames)
        XCTAssertTrue(queue.drainIssues().contains { $0.message.contains("lost") })
    }

    func testSourcesOverlapAndUseOneTimelineAndFlushOnStop() throws {
        let queue = MeetingAudioQueue()
        queue.append(Array(repeating: 0.1, count: 8000), source: .system, at: 4)
        queue.append(Array(repeating: 0.2, count: 8000), source: .microphone, at: 3.8)
        queue.finish(); queue.finish()
        let first = try XCTUnwrap(queue.pop()), second = try XCTUnwrap(queue.pop())
        XCTAssertEqual(first.source, .microphone); XCTAssertEqual(first.start, 3.8); XCTAssertEqual(first.end, 4.3, accuracy: 0.001)
        XCTAssertEqual(second.source, .system); XCTAssertEqual(second.start, 4)
        XCTAssertNil(queue.pop())
        queue.append([1], source: .system, at: 10)
        XCTAssertNil(queue.pop())
    }

    func testConvertsDifferentSourceRatesWithoutMixingOrAccumulatingDrift() throws {
        let queue = MeetingAudioQueue()
        for (source, rate) in [(MeetingSource.microphone, 44_100.0), (.system, 48_000.0)] {
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false))
            let converter = try MeetingPCMConverter(format: format)
            for step in 0..<100 {
                let frames = AVAudioFrameCount(rate / 10)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
                buffer.frameLength = frames
                for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0.2, count: Int(frames)) }
                converter.consume(buffer, source: source, at: Double(step) / 10, into: queue)
            }
        }
        queue.finish()
        let chunks = [try XCTUnwrap(queue.pop()), try XCTUnwrap(queue.pop())]
        XCTAssertEqual(Set(chunks.map(\.source)), Set(MeetingSource.allCases))
        for chunk in chunks { XCTAssertEqual(chunk.end, 10, accuracy: 0.1) }
        XCTAssertTrue(queue.drainIssues().isEmpty)
    }

    func testClockDiscontinuityIsNotCollapsedIntoSpeech() {
        let queue = MeetingAudioQueue()
        queue.append(Array(repeating: 0.2, count: 1600), source: .system, at: 0)
        queue.append(Array(repeating: 0.2, count: 1600), source: .system, at: 5)
        queue.finish()
        XCTAssertEqual(queue.pop()?.start, 0); XCTAssertEqual(queue.pop()?.start, 5)
        XCTAssertTrue(queue.drainIssues().contains { $0.start <= 0.11 && $0.end == 5 })
    }

    func testShortcutLatchNeverTogglesOnRepeatsOrRelease() {
        var latch = ShortcutPressLatch()
        XCTAssertFalse(latch.update(pressed: false))
        XCTAssertTrue(latch.update(pressed: true))
        XCTAssertFalse(latch.update(pressed: true))
        XCTAssertFalse(latch.update(pressed: false))
        XCTAssertTrue(latch.update(pressed: true))
    }

    func testMeetingShortcutConflictsAndFnChordRejected() throws {
        var settings = AppSettings.defaults
        settings.meetingShortcut = "control+option+space"
        XCTAssertFalse(ShortcutParser.conflicts(settings.shortcutBindings).isEmpty)
        settings.meetingShortcut = settings.pasteLastShortcut
        XCTAssertFalse(ShortcutParser.conflicts(settings.shortcutBindings).isEmpty)
        // Both modifier orders are unsupported, rather than pretending to handle the chord.
        XCTAssertThrowsError(try ShortcutParser.parse("cmd+fn"))
        XCTAssertThrowsError(try ShortcutParser.parse("fn+cmd"))
        XCTAssertEqual(try ShortcutParser.parse("cmd+ctrl+m"), try ShortcutParser.parse("ctrl+cmd+m"))
    }

    func testExportOrdersSourceSegmentsAndDisclosesIssues() {
        var session = MeetingSession(startedAt: Date(timeIntervalSince1970: 0), engine: "Local", locale: "en-US")
        session.segments = [MeetingSegment(source: .system, start: 10, end: 13, text: "Remote"), MeetingSegment(source: .microphone, start: 9, end: 12, text: "Local")]
        session.issues = [MeetingIssue(start: 13, end: 14, message: "Missing interval")]
        XCTAssertEqual(session.orderedSegments.map(\.text), ["Local", "Remote"])
        XCTAssertTrue(session.markdown.contains("[00:00:09–00:00:12] **You:** Local"))
        XCTAssertTrue(session.markdown.contains("System audio")); XCTAssertTrue(session.markdown.contains("Missing interval"))
    }
}

/// The audio framework calls these blocks off the main actor, even though capture starts on it.
@MainActor
final class MeetingAudioCallbackTests: XCTestCase {
    func testMicrophoneCallbackAcceptsBuffersOnBackgroundAudioQueue() async throws {
        let queue = MeetingAudioQueue()
        let buffer = try makeBuffer()
        let origin = ProcessInfo.processInfo.systemUptime
        let time = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: origin + 2))
        let invocation = MicrophoneCallbackInvocation(
            callback: try MeetingCapture.microphoneCallback(format: buffer.format, queue: queue, origin: origin),
            buffer: buffer, time: time)
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "test.flowtype.microphone-callback").async {
                invocation.run()
                continuation.resume()
            }
        }
        queue.finish()
        let chunk = try XCTUnwrap(queue.pop())
        XCTAssertEqual(chunk.source, .microphone)
        XCTAssertEqual(chunk.start, 2, accuracy: 0.01)
        XCTAssertEqual(chunk.end, 2.1, accuracy: 0.02)
        XCTAssertGreaterThan(chunk.peak, 0.1)
    }

    func testSystemCallbackAcceptsBuffersOnBackgroundAudioQueue() async throws {
        let queue = MeetingAudioQueue()
        let buffer = try makeBuffer()
        let origin = ProcessInfo.processInfo.systemUptime
        let invocation = SystemCallbackInvocation(
            callback: try MeetingCapture.systemCallback(format: buffer.format, queue: queue, origin: origin),
            buffer: buffer, hostTime: AVAudioTime.hostTime(forSeconds: origin + 3))
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "test.flowtype.system-callback").async {
                invocation.run()
                continuation.resume()
            }
        }
        queue.finish()
        let chunk = try XCTUnwrap(queue.pop())
        XCTAssertEqual(chunk.source, .system)
        XCTAssertEqual(chunk.start, 3, accuracy: 0.01)
        XCTAssertEqual(chunk.end, 3.1, accuracy: 0.02)
        XCTAssertGreaterThan(chunk.peak, 0.1)
    }

    private func makeBuffer() throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0.2, count: 4800) }
        return buffer
    }
}

// Test buffers/blocks are transferred to exactly one serial callback queue and are immutable there.
private struct MicrophoneCallbackInvocation: @unchecked Sendable {
    let callback: AVAudioNodeTapBlock
    let buffer: AVAudioPCMBuffer
    let time: AVAudioTime
    func run() { callback(buffer, time) }
}
private struct SystemCallbackInvocation: @unchecked Sendable {
    let callback: AudioDeviceIOBlock
    let buffer: AVAudioPCMBuffer
    let hostTime: UInt64
    func run() {
        var time = AudioTimeStamp()
        time.mHostTime = hostTime
        time.mFlags = .hostTimeValid
        withUnsafePointer(to: &time) { stamp in
            callback(stamp, buffer.audioBufferList, stamp, buffer.mutableAudioBufferList, stamp)
        }
    }
}

@MainActor
final class MeetingControllerTests: XCTestCase {
    private func setup() -> (MeetingController, TestMeetingCapture, TestMeetingTranscriber, TestMeetingStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "MeetingTests-\(UUID().uuidString)")!
        let capture = TestMeetingCapture(), transcriber = TestMeetingTranscriber(), store = TestMeetingStore()
        let controller = MeetingController(capture: capture, transcriber: transcriber, store: store, defaults: defaults,
            microphoneAuthorized: { true }, requestMicrophone: { false })
        controller.openStore()
        return (controller, capture, transcriber, store, defaults)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for state transition")
    }

    func testDuplicateStartStopFinalizesBothSourcesWithoutPasteOrSnippets() async throws {
        let (controller, capture, transcriber, store, _) = setup()
        controller.start(microphoneUID: ""); controller.start(microphoneUID: "")
        try await wait { controller.phase == .recording }
        XCTAssertEqual(capture.starts, 1)
        capture.emit(source: .system, at: 2); capture.emit(source: .microphone, at: 1)
        controller.stop(); controller.stop()
        try await wait { !controller.isBusy }
        let session = try XCTUnwrap(controller.sessions.first)
        XCTAssertEqual(session.orderedSegments.map(\.source), [.microphone, .system])
        XCTAssertEqual(session.orderedSegments.map(\.text), ["literal snippet trigger", "literal snippet trigger"])
        XCTAssertEqual(transcriber.chunks.count, 2)
        XCTAssertEqual(store.saved[session.id]?.segments.count, 2)
        XCTAssertNotNil(session.endedAt)
    }

    func testCaptureFailureCannotSucceedEmpty() async throws {
        let (controller, capture, _, _, _) = setup(); capture.startFailure = true
        controller.start(microphoneUID: "")
        try await wait { !controller.isBusy }
        XCTAssertTrue(controller.message.contains("did not start"))
        XCTAssertFalse(controller.sessions.first?.issues.isEmpty ?? true)
    }

    func testModelFailurePreservesEarlierSourceAndSurfacesPartial() async throws {
        let (controller, capture, transcriber, _, _) = setup()
        transcriber.failOnSource = .system
        controller.start(microphoneUID: "")
        try await wait { controller.phase == .recording }
        capture.emit(source: .microphone, at: 1); capture.emit(source: .system, at: 2)
        controller.stop()
        try await wait { !controller.isBusy }
        XCTAssertEqual(controller.sessions.first?.segments.count, 1)
        XCTAssertTrue(controller.sessions.first?.status.hasPrefix("Partial") ?? false)
        XCTAssertTrue(controller.sessions.first?.issues.contains { $0.start == 2 && $0.message.contains("failed") } ?? false)
    }

    func testPermissionDenialDoesNotStartCapture() async throws {
        let capture = TestMeetingCapture()
        let controller = MeetingController(capture: capture, transcriber: TestMeetingTranscriber(), store: TestMeetingStore(),
            defaults: UserDefaults(suiteName: "Permission-\(UUID())")!, microphoneAuthorized: { false }, requestMicrophone: { false })
        controller.start(microphoneUID: "")
        try await wait { !controller.isBusy }
        XCTAssertEqual(capture.starts, 0); XCTAssertTrue(controller.message.contains("Microphone access"))
    }

    func testDictationBusyBlocksMeetingAndUnverifiedAutoCannotPrompt() {
        let (controller, capture, transcriber, _, _) = setup()
        controller.canStart = { false }; controller.start(microphoneUID: "")
        XCTAssertFalse(controller.isBusy)
        controller.canStart = { true }; controller.start(microphoneUID: "", automatic: true)
        XCTAssertFalse(controller.isBusy); XCTAssertEqual(capture.starts, 0); XCTAssertEqual(transcriber.prepares, 0)
    }

    func testMeetingAndDictationCoordinateWithoutPastingMeetingText() async throws {
        let (meetings, capture, _, _, defaults) = setup()
        let settings = SettingsStore(defaults: defaults, apiKeyStore: UserDefaultsGroqAPIKeyStore(defaults: defaults))
        var value = settings.load(); value.playSounds = false; value.transcriptionProvider = .groq; value.groqAPIKey = "test"; settings.save(value)
        let audio = IntegrationAudio(), paste = IntegrationPaste(), dictation = IntegrationTranscriber()
        let app = AppStateController(settingsStore: settings, meetings: meetings, audio: audio, transcriber: dictation, pasteService: paste,
            permissions: { PermissionStatus(microphone: .authorized, accessibility: true) })
        meetings.start(microphoneUID: "")
        try await wait { meetings.phase == .recording }
        XCTAssertFalse(app.startRecording(mode: .handsFree))
        capture.emit(source: .microphone, at: 0); meetings.stop()
        try await wait { !meetings.isBusy }
        XCTAssertTrue(paste.inserted.isEmpty); XCTAssertEqual(paste.targets, 0)
        XCTAssertNil(app.lastTranscript); XCTAssertEqual(audio.starts, 0); XCTAssertEqual(dictation.calls, 0)
        XCTAssertEqual(meetings.sessions.first?.segments.first?.text, "literal snippet trigger")
        XCTAssertTrue(app.startRecording(mode: .handsFree))
        meetings.start(microphoneUID: "")
        XCTAssertFalse(meetings.isBusy)
        app.cancel()
    }

    func testCancelDuringPreparationNeverStartsCapture() async throws {
        let (controller, capture, transcriber, _, _) = setup()
        transcriber.slowPreparation = true
        controller.start(microphoneUID: "")
        controller.stop()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(controller.isBusy); XCTAssertEqual(capture.starts, 0)
    }

    func testCancellationDuringFinalizationPreservesCompletedSegmentsAndDisclosesDiscardedAudio() async throws {
        let (controller, capture, transcriber, _, _) = setup()
        controller.start(microphoneUID: "")
        try await wait { controller.phase == .recording }
        for second in 0..<20 {
            capture.queue?.append(Array(repeating: 0.2, count: 16000), source: .microphone, at: Double(second))
        }
        try await wait { controller.current?.segments.count == 1 }
        transcriber.slowTranscription = true
        capture.emit(source: .microphone, at: 20); capture.emit(source: .system, at: 20)
        controller.stop()
        try await wait { transcriber.chunks.count == 2 }
        controller.cancelPendingTranscription()
        try await wait { !controller.isBusy }
        XCTAssertEqual(controller.sessions.first?.segments.count, 1)
        XCTAssertTrue(controller.sessions.first?.issues.contains { $0.message.contains("cancelled") } ?? false)
    }

    func testMaximumDurationAndAbsentSystemStreamStopCapture() async throws {
        var clock = 100.0
        let capture = TestMeetingCapture()
        let controller = MeetingController(capture: capture, transcriber: TestMeetingTranscriber(), store: TestMeetingStore(),
            defaults: UserDefaults(suiteName: "Health-\(UUID())")!, uptime: { clock }, microphoneAuthorized: { true })
        controller.preferences.maximumMinutes = 1
        controller.start(microphoneUID: "")
        try await wait { controller.phase == .recording }
        clock = 161; controller.checkHealth()
        try await wait { !controller.isBusy }
        XCTAssertTrue(controller.sessions.first?.issues.contains { $0.message.contains("maximum duration") } ?? false)
        clock = 200; controller.start(microphoneUID: "")
        try await wait { controller.phase == .recording }
        capture.emit(source: .microphone, at: 15)
        clock = 216; controller.checkHealth()
        try await wait { !controller.isBusy }
        XCTAssertTrue(controller.sessions.first?.issues.contains { $0.message.contains("System audio stopped") } ?? false)
    }

    func testDefaultCloudBoundaryAndIndependentPreferences() {
        let (controller, _, _, _, defaults) = setup()
        let settings = SettingsStore(defaults: defaults, apiKeyStore: UserDefaultsGroqAPIKeyStore(defaults: defaults))
        var dictation = settings.load(); dictation.transcriptionProvider = .groq; settings.save(dictation)
        XCTAssertEqual(controller.preferences.engine, .automatic)
        XCTAssertFalse(controller.preferences.retainAudio)
        XCTAssertEqual(controller.preferences.calendarMode, .off)
        // MeetingEngine cannot represent Groq/cloud, including when decoding modified preferences.
        XCTAssertNil(MeetingEngine(rawValue: "groq"))
        controller.preferences.retainAudio = true
        XCTAssertTrue(MeetingPreferences.load(defaults).retainAudio)
        XCTAssertEqual(settings.load().transcriptionProvider, .groq)
    }

    func testStorageFailureStopsAndKeepsExportableMemoryResults() async throws {
        let (controller, capture, _, store, _) = setup()
        controller.start(microphoneUID: "")
        try await wait { controller.phase == .recording }
        store.failSave = true
        capture.emit(source: .microphone, at: 1)
        controller.stop()
        try await wait { !controller.isBusy }
        XCTAssertEqual(controller.sessions.first?.segments.count, 1)
        XCTAssertTrue(controller.message.contains("Export"))
    }

    func testInterruptionStopsAndFlushesPendingAudio() async throws {
        let (controller, capture, _, _, _) = setup()
        controller.start(microphoneUID: "")
        try await wait { controller.phase == .recording }
        capture.emit(source: .microphone, at: 0)
        capture.onFailure?("Input device changed")
        try await wait { !controller.isBusy }
        XCTAssertEqual(controller.sessions.first?.segments.count, 1)
        XCTAssertTrue(controller.sessions.first?.issues.contains { $0.message == "Input device changed" } ?? false)
    }

    func testNeverSaveDoesNotWriteTranscriptAndDeleteRemovesAudio() async throws {
        let (controller, capture, _, store, _) = setup()
        controller.preferences.saveTranscript = false
        controller.start(microphoneUID: "")
        try await wait { controller.phase == .recording }
        capture.emit(source: .microphone, at: 0); controller.stop()
        try await wait { !controller.isBusy }
        let session = try XCTUnwrap(controller.sessions.first)
        XCTAssertFalse(session.savesTranscript)
        controller.delete(session)
        XCTAssertTrue(controller.sessions.isEmpty); XCTAssertEqual(store.deleted, [session.id])
    }
}

@MainActor
final class MeetingPersistenceTests: XCTestCase {
    func testPrivateStoreRecoveryRetentionAndAudioOptIn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingStore-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingFileStore(root: root)
        let date = Date(timeIntervalSince1970: 1_000_000)
        var session = MeetingSession(startedAt: date, engine: "Test", locale: "en-US", transcriptRetentionHours: 24)
        session.segments = [MeetingSegment(source: .microphone, start: 0, end: 1, text: "Recover me")]
        try store.save(session)
        XCTAssertEqual(try store.load().first?.segments.first?.text, "Recover me")
        let folder = root.appendingPathComponent(session.id.uuidString)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("session.json").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let chunk = MeetingChunk(source: .system, start: 0, samples: [0, 0.2])
        try store.saveAudio(chunk, session: session)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Audio").path))
        let controller = MeetingController(capture: TestMeetingCapture(), transcriber: TestMeetingTranscriber(), store: store,
            defaults: UserDefaults(suiteName: "Recover-\(UUID())")!, now: { date.addingTimeInterval(1) })
        controller.openStore()
        XCTAssertTrue(controller.sessions.first?.status.hasPrefix("Interrupted") ?? false)
        session.retainsAudio = true; session.audioRetentionDays = 1; session.endedAt = date
        try store.save(session); try store.saveAudio(chunk, session: session)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Audio").path))
        try store.applyRetention(now: date.addingTimeInterval(86401), excluding: nil)
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testNeverSaveAndCorruptFilesAreNotSilentlyReplaced() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingStore-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingFileStore(root: root)
        var session = MeetingSession(startedAt: .now, engine: "Test", locale: "en-US", savesTranscript: false)
        session.segments = [MeetingSegment(source: .microphone, start: 0, end: 1, text: "Private")]
        try store.save(session); XCTAssertTrue(try store.load().isEmpty)
        session.retainsAudio = true
        try store.save(session); XCTAssertTrue(try XCTUnwrap(store.load().first).segments.isEmpty)
        let url = root.appendingPathComponent(session.id.uuidString).appendingPathComponent("session.json")
        try Data("corrupt".utf8).write(to: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "corrupt")
    }

    func testRealDiskCopyOfPreFeatureSwiftDataSchemaReopensWithoutFallback() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FlowtypeMigration-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("before.store")
        let schema = Schema(NativeSchema.models) // Exact unchanged schema from 0a239a8.
        do {
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: original))
            let context = container.mainContext
            context.insert(TranscriptHistoryItem(transcript: "Existing dictation", pasted: true, statusMessage: "Pasted"))
            context.insert(Snippet(trigger: "test", expansion: "Existing snippet"))
            context.insert(ScratchpadNote(title: "Existing note", body: "Preserved"))
            context.insert(DictionaryEntry(phrase: "Flowtype"))
            context.insert(DailyUsage(day: "2026-11-12", words: 42))
            context.insert(AppCategory(pattern: "existing", category: "work"))
            try context.save()
        }
        let copy = folder.appendingPathComponent("copy.store")
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: original.path + suffix)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }
        // Direct open: no NativeSchema.makeContainer fallback is involved.
        let reopened = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: copy))
        XCTAssertEqual(try reopened.mainContext.fetch(FetchDescriptor<TranscriptHistoryItem>()).first?.transcript, "Existing dictation")
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<Snippet>()), 1)
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<ScratchpadNote>()), 1)
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<DictionaryEntry>()), 1)
        XCTAssertEqual(try reopened.mainContext.fetch(FetchDescriptor<DailyUsage>()).first?.words, 42)
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<AppCategory>()), 1)
    }
}

@MainActor
final class MeetingCalendarTests: XCTestCase {
    func testEligibilityRequiresSelectedCalendarsFiltersAndTimedEvents() {
        var preferences = MeetingPreferences(); preferences.calendarIDs = ["chosen"]
        var event = MeetingEvent(id: "one", calendarID: "chosen", start: .now, end: .now.addingTimeInterval(300), hasConference: true)
        XCTAssertTrue(MeetingCalendarScheduler.eligible(event, preferences: preferences))
        event.allDay = true; XCTAssertFalse(MeetingCalendarScheduler.eligible(event, preferences: preferences)); event.allDay = false
        event.cancelled = true; XCTAssertFalse(MeetingCalendarScheduler.eligible(event, preferences: preferences)); event.cancelled = false
        event.calendarID = "other"; XCTAssertFalse(MeetingCalendarScheduler.eligible(event, preferences: preferences)); event.calendarID = "chosen"
        event.hasConference = false; XCTAssertFalse(MeetingCalendarScheduler.eligible(event, preferences: preferences))
        preferences.requireConferenceLink = false; preferences.requireAttendees = true
        XCTAssertFalse(MeetingCalendarScheduler.eligible(event, preferences: preferences))
        event.hasAttendees = true; XCTAssertTrue(MeetingCalendarScheduler.eligible(event, preferences: preferences))
    }

    func testOccurrenceIdentitySurvivesMovesAndSeparatesRecurringInstancesWithoutStoringContents() {
        let day = Date(timeIntervalSince1970: 1_000_000)
        let single = MeetingOccurrenceID.make(itemIdentifier: "external-guid", originalOccurrence: nil)
        XCTAssertEqual(single, MeetingOccurrenceID.make(itemIdentifier: "external-guid", originalOccurrence: nil))
        let first = MeetingOccurrenceID.make(itemIdentifier: "series-guid", originalOccurrence: day)
        XCTAssertEqual(first, MeetingOccurrenceID.make(itemIdentifier: "series-guid", originalOccurrence: day))
        XCTAssertNotEqual(first, MeetingOccurrenceID.make(itemIdentifier: "series-guid", originalOccurrence: day.addingTimeInterval(86400)))
        XCTAssertEqual(first.count, 64); XCTAssertFalse(first.contains("series-guid"))
    }

    func testOffDoesNotReadCalendarAndDeniedDoesNotStart() {
        let defaults = UserDefaults(suiteName: "Calendar-\(UUID())")!
        let meeting = MeetingController(capture: TestMeetingCapture(), transcriber: TestMeetingTranscriber(), store: TestMeetingStore(), defaults: defaults)
        let provider = TestMeetingEvents()
        let scheduler = MeetingCalendarScheduler(meetings: meeting, events: provider, defaults: defaults)
        scheduler.tick(); XCTAssertEqual(provider.reads, 0)
        meeting.preferences.calendarMode = .autoStart; provider.authorized = false
        scheduler.tick(); XCTAssertEqual(provider.reads, 0); XCTAssertFalse(meeting.isBusy)
    }

    func testOccurrenceDeduplicationCancellationOverlapRestartAndWake() {
        let defaults = UserDefaults(suiteName: "Calendar-\(UUID())")!
        var now = Date(timeIntervalSince1970: 1_000_000)
        let meeting = MeetingController(capture: TestMeetingCapture(), transcriber: TestMeetingTranscriber(), store: TestMeetingStore(), defaults: defaults)
        meeting.preferences.calendarMode = .suggest; meeting.preferences.calendarIDs = ["chosen"]
        let provider = TestMeetingEvents()
        let event = MeetingEvent(id: "series-occurrence-1", calendarID: "chosen", start: now, end: now.addingTimeInterval(1800), hasConference: true)
        provider.snapshot = [event]
        let scheduler = MeetingCalendarScheduler(meetings: meeting, events: provider, defaults: defaults, now: { now })
        scheduler.tick(); XCTAssertNotNil(scheduler.suggestion); XCTAssertFalse(meeting.isBusy)
        scheduler.skip(); scheduler.tick(); XCTAssertNil(scheduler.suggestion)
        let restarted = MeetingCalendarScheduler(meetings: meeting, events: provider, defaults: defaults, now: { now })
        restarted.tick(); XCTAssertNil(restarted.suggestion)
        var next = event; next.id = "series-occurrence-2"; next.start = now.addingTimeInterval(86400); next.end = next.start.addingTimeInterval(1800)
        now = next.start; provider.snapshot = [next]
        restarted.tick(); XCTAssertEqual(restarted.suggestion?.id, next.id)
        provider.snapshot[0].cancelled = true; restarted.tick(); XCTAssertNil(restarted.suggestion)
        var missed = next; missed.id = "missed-on-wake"; missed.start = now.addingTimeInterval(-300)
        provider.snapshot = [missed]; now = now.addingTimeInterval(120)
        restarted.tick(); XCTAssertNil(restarted.suggestion)
        let sameInstant = ISO8601DateFormatter().date(from: "2026-11-12T12:00:00Z")!
        let offsetInstant = ISO8601DateFormatter().date(from: "2026-11-12T16:00:00+04:00")!
        XCTAssertEqual(sameInstant, offsetInstant)
        var zoned = next; zoned.id = "timezone-event"; zoned.start = offsetInstant; zoned.end = offsetInstant.addingTimeInterval(900)
        now = sameInstant; provider.snapshot = [zoned]
        restarted.tick(); XCTAssertEqual(restarted.suggestion?.id, zoned.id)
    }

    func testVerifiedAutoStartHasNoDownloadAndStopsOnCancellationOrRevokedAccess() async throws {
        let defaults = UserDefaults(suiteName: "CalendarAuto-\(UUID())")!
        let capture = TestMeetingCapture(), transcriber = TestMeetingTranscriber()
        let meeting = MeetingController(capture: capture, transcriber: transcriber, store: TestMeetingStore(), defaults: defaults,
            uptime: { 100 }, microphoneAuthorized: { true })
        meeting.preferences.calendarMode = .autoStart; meeting.preferences.calendarIDs = ["chosen"]
        meeting.start(microphoneUID: "")
        for _ in 0..<100 where meeting.phase != .recording { try await Task.sleep(for: .milliseconds(10)) }
        capture.emit(source: .microphone, at: 0); capture.emit(source: .system, at: 0)
        meeting.checkHealth(); XCTAssertTrue(meeting.automaticReady)
        meeting.stop()
        for _ in 0..<100 where meeting.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        let time = Date()
        let provider = TestMeetingEvents()
        provider.snapshot = [MeetingEvent(id: "scheduled", calendarID: "chosen", start: time, end: time.addingTimeInterval(300), hasConference: true)]
        let scheduler = MeetingCalendarScheduler(meetings: meeting, events: provider, defaults: defaults, now: { time })
        scheduler.tick()
        for _ in 0..<100 where meeting.phase != .recording { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(capture.starts, 2); XCTAssertEqual(transcriber.downloadPermissions, [true, false])
        provider.snapshot[0].cancelled = true; scheduler.tick()
        for _ in 0..<100 where meeting.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(meeting.sessions.first?.issues.contains { $0.message.contains("cancelled") } ?? false)
        provider.snapshot[0].id = "scheduled-two"; provider.snapshot[0].cancelled = false; scheduler.tick()
        for _ in 0..<100 where meeting.phase != .recording { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(capture.starts, 3)
        provider.authorized = false; scheduler.tick()
        for _ in 0..<100 where meeting.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(meeting.sessions.first?.issues.contains { $0.message.contains("revoked") } ?? false)
    }

    func testMovedSuggestionCannotStartAndOverlappingSuggestionsAreSkipped() {
        let defaults = UserDefaults(suiteName: "Calendar-\(UUID())")!
        let now = Date()
        let meeting = MeetingController(capture: TestMeetingCapture(), transcriber: TestMeetingTranscriber(), store: TestMeetingStore(), defaults: defaults)
        meeting.preferences.calendarMode = .suggest; meeting.preferences.calendarIDs = ["chosen"]
        let provider = TestMeetingEvents()
        let first = MeetingEvent(id: "first", calendarID: "chosen", start: now, end: now.addingTimeInterval(500), hasConference: true)
        var second = first; second.id = "second"
        provider.snapshot = [first, second]
        let scheduler = MeetingCalendarScheduler(meetings: meeting, events: provider, defaults: defaults, now: { now })
        scheduler.tick(); XCTAssertEqual(scheduler.suggestion?.id, "first")
        provider.snapshot[0].start = now.addingTimeInterval(3600)
        scheduler.accept(); XCTAssertFalse(meeting.isBusy); XCTAssertNil(scheduler.suggestion)
        scheduler.tick(); XCTAssertNil(scheduler.suggestion)
    }
}

@MainActor private final class TestMeetingCapture: MeetingCapturing {
    var onFailure: ((String) -> Void)?
    var starts = 0
    var startFailure = false
    var queue: MeetingAudioQueue?
    func start(queue: MeetingAudioQueue, origin: Double, microphoneUID: String) async throws {
        starts += 1
        if startFailure { throw MeetingError.message("Test capture denied") }
        self.queue = queue
    }
    func emit(source: MeetingSource, at time: Double) { queue?.append(Array(repeating: 0.2, count: 1600), source: source, at: time) }
    func stop() {}
}
@MainActor private final class TestMeetingTranscriber: MeetingTranscribing {
    var prepares = 0
    var slowPreparation = false
    var slowTranscription = false
    var downloadPermissions: [Bool] = []
    var chunks: [MeetingChunk] = []
    var failOnSource: MeetingSource?
    func prepare(_ preferences: MeetingPreferences, allowDownload: Bool) async throws -> String {
        prepares += 1; downloadPermissions.append(allowDownload)
        if slowPreparation { try await Task.sleep(for: .milliseconds(100)) }
        return "Test local"
    }
    func transcribe(_ chunk: MeetingChunk, preferences: MeetingPreferences) async throws -> [MeetingSegment] {
        chunks.append(chunk)
        if slowTranscription { try await Task.sleep(for: .seconds(2)) }
        if failOnSource == chunk.source { throw MeetingError.message("Test model failure") }
        return [MeetingSegment(source: chunk.source, start: chunk.start, end: chunk.end, text: "literal snippet trigger")]
    }
}
@MainActor private final class TestMeetingStore: MeetingStoring {
    var saved: [UUID: MeetingSession] = [:]
    var deleted: [UUID] = []
    var failSave = false
    func load() throws -> [MeetingSession] { Array(saved.values) }
    func save(_ session: MeetingSession) throws {
        if failSave { throw MeetingError.message("Test disk full") }
        guard session.savesTranscript || session.retainsAudio else { return }
        saved[session.id] = session
    }
    func saveAudio(_ chunk: MeetingChunk, session: MeetingSession) throws {}
    func delete(_ id: UUID) throws { deleted.append(id); saved[id] = nil }
    func deleteAudio(_ id: UUID) throws {}
    func applyRetention(now: Date, excluding: UUID?) throws {}
}
@MainActor private final class TestMeetingEvents: MeetingEventProviding {
    var authorized = true
    var reads = 0
    var snapshot: [MeetingEvent] = []
    func requestAccess() async throws -> Bool { authorized }
    func calendars() -> [MeetingCalendarChoice] { [] }
    func events(from: Date, to: Date, calendarIDs: [String]) throws -> [MeetingEvent] { reads += 1; return snapshot }
}

@MainActor private final class IntegrationPaste: Pasting {
    var targets = 0
    var inserted: [String] = []
    func captureTarget() -> PasteTarget? { targets += 1; return nil }
    func insert(_ text: String, into target: PasteTarget?, restoreClipboard: Bool) async -> PasteOutcome { inserted.append(text); return .pasted }
}
private final class IntegrationAudio: AudioCapturing {
    var starts = 0
    var isRecording = false
    var onLevel: (@MainActor (Float) -> Void)?
    var onInterruption: (@MainActor () -> Void)?
    func start(deviceUID: String?) throws { starts += 1; isRecording = true }
    func stop() -> RecordedAudio? { isRecording = false; return nil }
    func cancel() { isRecording = false }
}
@MainActor private final class IntegrationTranscriber: Transcribing {
    var calls = 0
    func transcribe(_ audio: RecordedAudio, settings: AppSettings, vocabulary: [String]) async throws -> String { calls += 1; return "dictation" }
    func modelStatus(settings: AppSettings) -> TranscriptionModelStatus { .init(modelName: "Fake", isReady: true, localPath: nil) }
    func prepare(settings: AppSettings, progress: ModelPreparationProgress?) async throws {}
    func isLoaded(settings: AppSettings) -> Bool { true }
    func unloadModel() {}
    func unloadWhisperModel() {}
    func deleteDownloadedModels() throws {}
}
