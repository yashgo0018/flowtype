import AppKit
import Combine
import Foundation

@MainActor
protocol MeetingTranscribing: AnyObject {
    func prepare(_ preferences: MeetingPreferences, allowDownload: Bool) async throws -> String
    func transcribe(_ chunk: MeetingChunk, preferences: MeetingPreferences) async throws -> [MeetingSegment]
    func releaseModel()
}

extension MeetingTranscribing { func releaseModel() {} }

@MainActor
final class LocalMeetingTranscriber: MeetingTranscribing {
    private let whisper = WhisperKitTranscriptionService()
    private var usesApple = false
    func prepare(_ preferences: MeetingPreferences, allowDownload: Bool) async throws -> String {
        usesApple = preferences.engine == .automatic && AppleSpeech.isSupported
        if usesApple, #available(macOS 26, *) {
            guard await SpeechLocaleSupport.supports(preferences.locale) else {
                throw MeetingError.message("Apple Speech does not support this meeting language. Select Whisper with a multilingual model or another language.")
            }
            try await AppleSpeechTranscriptionService.prepareMeeting(locale: preferences.locale, allowDownload: allowDownload)
            return "Apple Speech (on device)"
        }
        if preferences.whisperModel.hasSuffix(".en"), !preferences.locale.lowercased().hasPrefix("en") {
            throw MeetingError.message("This Whisper model supports English only. Select Large v3 Turbo for other languages.")
        }
        guard WhisperKitTranscriptionService.supportsMeetingLanguage(preferences.locale) else {
            throw MeetingError.message("Whisper does not support this meeting language code.")
        }
        var settings = AppSettings.defaults
        settings.transcriptionProvider = .local
        settings.transcriptionModel = preferences.whisperModel
        guard allowDownload || whisper.modelStatus(settings: settings).isReady else {
            throw MeetingError.message("The local meeting model is not installed. Prepare it with a manual capture before enabling automatic recording.")
        }
        try await whisper.prepare(settings: settings, progress: nil)
        return "Whisper (on device)"
    }
    func releaseModel() { whisper.unloadModel() }
    func transcribe(_ chunk: MeetingChunk, preferences: MeetingPreferences) async throws -> [MeetingSegment] {
        if usesApple, #available(macOS 26, *) {
            return try await AppleSpeechTranscriptionService.transcribeMeeting(chunk, locale: preferences.locale)
        }
        return try await whisper.transcribeMeeting(chunk, preferences: preferences)
    }
}

import Speech
private enum SpeechLocaleSupport {
    @available(macOS 26, *) static func supports(_ locale: String) async -> Bool {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) != nil
    }
}

enum MeetingPhase: String { case idle, preparing, recording, finalizing }

@MainActor
final class MeetingController: ObservableObject {
    @Published private(set) var phase: MeetingPhase = .idle
    @Published private(set) var sessions: [MeetingSession] = []
    @Published private(set) var current: MeetingSession?
    @Published private(set) var message = "Meetings are transcribed locally. Get participants’ permission before recording."
    @Published var preferences: MeetingPreferences { didSet { preferences.save(defaults) } }
    var isBusy: Bool { phase != .idle }
    var canStart: () -> Bool = { true }
    var onAnnounce: (() -> Void)?
    var onPhaseChange: (() -> Void)?
    private let capture: MeetingCapturing
    private let transcriber: MeetingTranscribing
    private var store: MeetingStoring?
    private let defaults: UserDefaults
    private let now: () -> Date
    private let uptime: () -> Double
    private let microphoneAuthorized: () -> Bool
    private let requestMicrophone: () async -> Bool
    private var queue: MeetingAudioQueue?
    private var worker: Task<Void, Never>?
    private var watchdog: Timer?
    private var activePreferences = MeetingPreferences()
    private var origin: Double = 0
    private var stopRequested = false
    private var prepareToken = UUID()
    private var preparation: Task<Void, Never>?
    private var silentNotice = false
    private var storeFailed = false
    @Published private(set) var verifiedSources = false
    private var preparedPreferences: MeetingPreferences?
    var scheduledID: String?
    var scheduledEnd: Date?

    init(capture: MeetingCapturing = MeetingCapture(), transcriber: MeetingTranscribing = LocalMeetingTranscriber(),
         store: MeetingStoring? = nil, defaults: UserDefaults = .standard,
         now: @escaping () -> Date = { .now }, uptime: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         microphoneAuthorized: @escaping () -> Bool = { PermissionStatus.current().microphoneGranted },
         requestMicrophone: @escaping () async -> Bool = { await PermissionService.requestMicrophoneAccess() }) {
        self.capture = capture; self.transcriber = transcriber; self.store = store; self.defaults = defaults
        self.now = now; self.uptime = uptime; self.microphoneAuthorized = microphoneAuthorized; self.requestMicrophone = requestMicrophone
        preferences = .load(defaults)
        capture.onFailure = { [weak self] text in self?.verifiedSources = false; self?.stop(reason: text) }
    }

    func openStore() {
        do {
            if store == nil { store = try MeetingFileStore() }
            storeFailed = false
            var recovered = try store?.load() ?? []
            for index in recovered.indices where recovered[index].endedAt == nil {
                recovered[index].endedAt = recovered[index].startedAt.addingTimeInterval(recovered[index].duration)
                recovered[index].status = "Interrupted — recovered partial transcript"
                recovered[index].issues.append(MeetingIssue(start: recovered[index].duration, end: recovered[index].duration,
                    message: "The app stopped before finalization. Unprocessed in-memory audio was lost; the uncommitted interval is unknown."))
                try store?.save(recovered[index])
            }
            try store?.applyRetention(now: now(), excluding: nil)
            sessions = try store?.load() ?? []
            if recovered.contains(where: { $0.status.hasPrefix("Interrupted") }) { message = "Recovered interrupted meetings. Review their capture notices for missing audio." }
        } catch { storeFailed = true; message = "Could not open meeting storage. Existing files were preserved. \(error.localizedDescription)" }
    }

    var automaticReady: Bool { verifiedSources && preparedPreferences == preferences && microphoneAuthorized() && !storeFailed }
    func invalidateSourceCheck() { verifiedSources = false; preparedPreferences = nil }

    func toggle(microphoneUID: String) {
        if isBusy { stop() } else { start(microphoneUID: microphoneUID) }
    }

    func start(microphoneUID: String, automatic: Bool = false) {
        guard !isBusy else { return }
        guard canStart() else { message = "Finish dictation or model preparation before starting a meeting."; return }
        guard !storeFailed else { return }
        if automatic && (!verifiedSources || preparedPreferences != preferences || !microphoneAuthorized()) {
            message = "Scheduled capture skipped. First complete a manual source check with these settings in this app launch."; return
        }
        if !automatic { verifiedSources = false }
        current = nil; queue = nil; scheduledID = nil; scheduledEnd = nil
        origin = uptime()
        activePreferences = preferences
        activePreferences.maximumMinutes = min(480, max(1, activePreferences.maximumMinutes))
        let token = UUID(); prepareToken = token
        stopRequested = false; silentNotice = false
        phase = .preparing; message = "Preparing local speech model… Capture has not started. Initial model installation may need internet."
        onPhaseChange?()
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                if !microphoneAuthorized() {
                    guard !automatic, await requestMicrophone() else { throw MeetingError.message("Microphone access is required. Enable Flowtype in Privacy & Security → Microphone.") }
                }
                try Task.checkCancellation()
                let engine = try await transcriber.prepare(activePreferences, allowDownload: !automatic)
                guard token == prepareToken, !Task.isCancelled else { return }
                preparedPreferences = activePreferences
                origin = uptime()
                current = MeetingSession(startedAt: now(), engine: engine, locale: activePreferences.locale,
                    savesTranscript: activePreferences.saveTranscript, retainsAudio: activePreferences.retainAudio,
                    transcriptRetentionHours: activePreferences.transcriptRetentionHours, audioRetentionDays: activePreferences.audioRetentionDays)
                try store?.save(current!)
                let inbox = MeetingAudioQueue(); queue = inbox
                // System permission is requested by Core Audio only when this explicitly enabled path starts.
                try await capture.start(queue: inbox, origin: origin, microphoneUID: microphoneUID)
                guard token == prepareToken, !Task.isCancelled else { capture.stop(); return }
                phase = .recording
                message = "Recording microphone + all apps’ system audio locally. Stop when the meeting ends."
                onPhaseChange?(); onAnnounce?()
                worker = Task { [weak self] in await self?.consume(inbox) }
                watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.checkHealth() }
                }
            } catch {
                guard token == prepareToken else { return }
                capture.stop(); queue?.finish()
                if current != nil {
                    addIssue("Capture could not start: \(error.localizedDescription)", start: 0, end: elapsed)
                    await finalize()
                }
                phase = .idle; message = "Meeting did not start: \(error.localizedDescription)"; onPhaseChange?()
            }
            preparation = nil
        }
    }

    var elapsed: Double { max(0, uptime() - origin) }

    func stop(reason: String? = nil) {
        guard isBusy, phase != .finalizing else { return }
        if phase == .preparing {
            preparation?.cancel(); preparation = nil; prepareToken = UUID()
            capture.stop(); queue?.finish()
            if current != nil {
                addIssue(reason ?? "Start was cancelled before capture was ready.", start: 0, end: elapsed)
                Task { await finalize() }
            } else { phase = .idle; message = "Meeting start cancelled."; onPhaseChange?() }
            return
        }
        if let reason { addIssue(reason, start: elapsed, end: elapsed) }
        capture.stop()
        watchdog?.invalidate(); watchdog = nil
        queue?.finish(); stopRequested = true
        current?.duration = elapsed
        phase = .finalizing; message = "Capture stopped. Finishing pending local transcription…"; onPhaseChange?()
    }

    func cancelPendingTranscription() {
        guard phase == .finalizing else { return }
        worker?.cancel()
        message = "Cancelling remaining transcription. Waiting for the local engine to release; completed text is preserved."
    }

    func checkHealth() {
        guard phase == .recording, let queue else { return }
        let time = elapsed
        if time >= Double(activePreferences.maximumMinutes) * 60 { stop(reason: "Stopped at the configured maximum duration."); return }
        if let scheduledEnd, activePreferences.stopAtEventEnd, now() >= scheduledEnd { stop(); return }
        for source in MeetingSource.allCases {
            let health = queue.health(source)
            if time > 12, time - (health.lastEnd ?? 0) > 10 {
                verifiedSources = false
                stop(reason: "\(source.title) stopped delivering audio. Check recording permission and your audio devices."); return
            }
        }
        let system = queue.health(.system), mic = queue.health(.microphone)
        if system.peak > 0.001 && mic.received > 0 { verifiedSources = true }
        if time > 30, system.peak < 0.001, !silentNotice {
            silentNotice = true
            message = "System audio is silent. Check playback and System Audio Recording permission. This session may be incomplete."
            addIssue("No audible system audio in the first 30 seconds. Check permissions/playback; silence cannot prove capture permission.", start: 0, end: time)
        }
        current?.duration = time
    }

    private func consume(_ inbox: MeetingAudioQueue) async {
        while true {
            if let chunk = inbox.pop() {
                if Task.isCancelled {
                    addIssue("\(chunk.source.title) pending transcription was cancelled; this interval was discarded.", start: chunk.start, end: chunk.end)
                    continue
                }
                do {
                    if let current { try store?.saveAudio(chunk, session: current) }
                    if chunk.peak >= 0.001 {
                        let result = try await transcriber.transcribe(chunk, preferences: activePreferences)
                        try Task.checkCancellation()
                        current?.segments += result.compactMap { segment in
                            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty, segment.start.isFinite, segment.end.isFinite else { return nil }
                            var valid = segment; valid.source = chunk.source; valid.text = text
                            valid.start = min(chunk.end, max(chunk.start, segment.start))
                            valid.end = max(valid.start, min(chunk.end, segment.end))
                            return valid
                        }
                    }
                } catch is CancellationError {
                    addIssue("\(chunk.source.title) transcription was cancelled; this interval may be missing.", start: chunk.start, end: chunk.end)
                } catch {
                    invalidateSourceCheck()
                    addIssue("\(chunk.source.title) transcription/audio storage failed; this interval may be missing.", start: chunk.start, end: chunk.end)
                    message = "A meeting chunk failed. Partial results are preserved. Stop and review capture notices."
                    stop(reason: "Stopped after a model or storage failure.")
                }
                current?.duration = max(current?.duration ?? 0, chunk.end)
                addIssues(inbox.drainIssues())
                persistCurrent()
            } else if stopRequested { break }
            else { try? await Task.sleep(for: .milliseconds(150)) }
        }
        addIssues(inbox.drainIssues())
        for source in MeetingSource.allCases where inbox.health(source).peak < 0.001 {
            addIssue("No audible \(source.title) was detected. This source may be silent or unavailable.", start: 0, end: current?.duration ?? 0)
        }
        await finalize()
    }

    private func addIssues(_ issues: [MeetingIssue]) { for issue in issues { addIssue(issue.message, start: issue.start, end: issue.end) } }
    private func addIssue(_ message: String, start: Double, end: Double) {
        if (current?.issues.count ?? 0) < 200 { current?.issues.append(MeetingIssue(start: start, end: end, message: message)) }
        else {
            current?.issues[199].end = max(current?.issues[199].end ?? 0, end)
            current?.issues[199].message = "Additional notices were truncated. More missing intervals may occur in this range."
        }
    }
    private func persistCurrent() {
        guard let current else { return }
        do { try store?.save(current) }
        catch {
            storeFailed = true
            addIssue("Transcript could not be saved to disk. Export this session before quitting.", start: current.duration, end: elapsed)
            stop(reason: "Stopped after storage failure; partial transcript remains in memory.")
            message = "Storage failed. Export the partial transcript before quitting."
        }
    }
    private func finalize() async {
        watchdog?.invalidate(); watchdog = nil
        if current?.segments.isEmpty == true {
            addIssue("No speech transcript was produced. This session must not be treated as a successful recording.", start: 0, end: current?.duration ?? 0)
        }
        current?.endedAt = now()
        current?.status = (current?.segments.isEmpty ?? true) ? "No transcript — review capture notices" : ((current?.issues.isEmpty ?? true) ? "Completed" : "Partial — review capture notices")
        persistCurrent()
        if let current { sessions.removeAll { $0.id == current.id }; sessions.insert(current, at: 0) }
        transcriber.releaseModel()
        queue = nil; worker = nil; scheduledID = nil; scheduledEnd = nil
        phase = .idle
        message = storeFailed ? "Storage failed. Export this transcript before quitting." : (current?.status ?? "Stopped")
        onPhaseChange?()
    }

    func housekeeping() {
        guard !isBusy, !storeFailed else { return }
        do {
            try store?.applyRetention(now: now(), excluding: nil)
            let ephemeral = sessions.filter { !$0.savesTranscript && !$0.retainsAudio }
            sessions = (try store?.load() ?? []) + ephemeral
            if let existing = current { current = sessions.first { $0.id == existing.id } }
        } catch { message = "Meeting retention could not complete: \(error.localizedDescription)" }
    }
    func delete(_ session: MeetingSession) {
        guard !isBusy else { return }
        do { try store?.delete(session.id); sessions.removeAll { $0.id == session.id }; if current?.id == session.id { current = nil } }
        catch { message = "Could not delete meeting: \(error.localizedDescription)" }
    }
    func deleteAudio(_ session: MeetingSession) {
        guard !isBusy else { return }
        do {
            try store?.deleteAudio(session.id)
            var updated = session; updated.retainsAudio = false
            if !updated.savesTranscript { try store?.delete(updated.id) } else { try store?.save(updated) }
            if current?.id == updated.id { current = updated }
            if let i = sessions.firstIndex(where: { $0.id == session.id }) { sessions[i] = updated }
        } catch { message = "Could not delete audio: \(error.localizedDescription)" }
    }
    func export(_ session: MeetingSession) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "Meeting-\(session.startedAt.formatted(.iso8601.year().month().day()))-\(session.id.uuidString.prefix(8)).md"
        if panel.runModal() == .OK, let url = panel.url {
            do { try session.markdown.write(to: url, atomically: true, encoding: .utf8) }
            catch { message = "Could not export transcript: \(error.localizedDescription)" }
        }
    }
}
