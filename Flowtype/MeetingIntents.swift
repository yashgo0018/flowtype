import AppIntents
import AppKit

@MainActor
enum MeetingActions {
    static weak var controller: AppStateController?
    static func start() throws -> String {
        guard let controller else { throw MeetingError.message("Open Flowtype once before running this action.") }
        guard !controller.meetings.isBusy else { return "A meeting is already active." }
        controller.showHub(.meetings)
        controller.meetings.start(microphoneUID: controller.settings.microphoneUID)
        return controller.meetings.message
    }
    static func stop() throws -> String {
        guard let controller else { throw MeetingError.message("Flowtype is not ready.") }
        guard controller.meetings.isBusy else { return "No meeting is active." }
        controller.meetings.stop()
        return controller.meetings.message
    }
}

struct StartMeetingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Meeting Capture"
    static let description = IntentDescription("Start local microphone and all-app system audio transcription in Flowtype. Obtain participant permission first. Capture begins after model and permission checks.")
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try MeetingActions.start()
        return .result(dialog: "\(message)")
    }
}
struct StopMeetingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Meeting Capture"
    static let description = IntentDescription("Stop capture and finalize pending local transcript segments.")
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try MeetingActions.stop()
        return .result(dialog: "\(message)")
    }
}
struct MeetingAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartMeetingIntent(), phrases: ["Start meeting capture in \(.applicationName)"], shortTitle: "Start Meeting", systemImageName: "record.circle")
        AppShortcut(intent: StopMeetingIntent(), phrases: ["Stop meeting capture in \(.applicationName)"], shortTitle: "Stop Meeting", systemImageName: "stop.circle")
    }
}
