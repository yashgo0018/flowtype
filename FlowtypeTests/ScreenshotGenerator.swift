import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Flowtype

/// Renders website and README screenshots from the real views with sample data.
///
///     TEST_RUNNER_FLOWTYPE_SCREENSHOTS_DIR="$PWD/docs/assets/screenshots" \
///       xcodebuild test -project Flowtype.xcodeproj -scheme Flowtype \
///       -destination 'platform=macOS,arch=arm64' -only-testing:FlowtypeTests/ScreenshotGenerator
@MainActor
final class ScreenshotGenerator: XCTestCase {
    private var outputDirectory: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["FLOWTYPE_SCREENSHOTS_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_FLOWTYPE_SCREENSHOTS_DIR to generate screenshots.")
        }
        outputDirectory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    func testRenderScreenshots() throws {
        let container = try sampleData()
        let controller = makeController()

        // Window background colors for each appearance, set explicitly because ImageRenderer resolves
        // dynamic NSColors against the light appearance.
        let variants: [(NSAppearance.Name, ColorScheme, Color, String)] = [
            (.darkAqua, .dark, Color(white: 0.118), "dark"),
            (.aqua, .light, Color(white: 0.925), "light")
        ]
        for (appearance, scheme, background, suffix) in variants {
            let home = HomeView()
                .environmentObject(controller)
                .modelContainer(container)
                .environment(\.pageScrollingDisabled, true)
                .environment(\.colorScheme, scheme)
                .frame(width: 860)
                .background(background)
            try renderPage(home, appearance: appearance, name: "home-\(suffix)")
        }

        let states: [(String, DictationPhase, Bool)] = [
            ("bar-idle", .idle, true),
            ("bar-recording", .recording(mode: .pushToTalk, startedAt: Date().addingTimeInterval(-12)), false),
            ("bar-transcribing", .transcribing, false),
            ("bar-pasted", .finished(Feedback(kind: .success, title: "Pasted", detail: "24 words")), false)
        ]
        for level: Float in [0.15, 0.4, 0.8, 0.55, 0.95, 0.7, 0.35, 0.85, 0.6, 0.3, 0.75, 0.5] {
            controller.levelMeter.push(level)
            controller.levelMeter.push(level * 0.65)
        }
        for (name, phase, hovering) in states {
            controller.setPhaseForScreenshots(phase)
            let model = FlowBarModel()
            model.isHovering = hovering
            model.pillSize = FlowBarLayout.size(phase: phase, activity: nil, hovering: hovering, settings: controller.settings)
            let bar = FlowBarView()
                .environmentObject(controller)
                .environmentObject(controller.levelMeter)
                .environmentObject(model)
            let margin = FlowBarPanelController.margin * 2
            try renderInWindow(bar, size: NSSize(width: model.pillSize.width + margin, height: model.pillSize.height + margin), name: name)
        }
    }

    // MARK: - Sample data

    private func makeController() -> AppStateController {
        let defaults = UserDefaults(suiteName: "screenshots-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults, apiKeyStore: UserDefaultsGroqAPIKeyStore(defaults: defaults))
        return AppStateController(
            settingsStore: store,
            transcriber: ReadyTranscriber(),
            permissions: { PermissionStatus(microphone: .authorized, accessibility: true) }
        )
    }

    private func sampleData() throws -> ModelContainer {
        let container = try ModelContainer(for: Schema(NativeSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let calendar = Calendar.current
        let words = [640, 910, 420, 760, 1180, 530, 980, 870, 0, 1320, 690, 1040, 0, 780]
        for (offset, count) in words.enumerated() {
            let day = calendar.date(byAdding: .day, value: -offset, to: .now)!
            let usage = DailyUsage(day: TextMetrics.dayKey(for: day), words: count, sessions: count / 40)
            usage.dictationSeconds = Double(count) / 152 * 60
            context.insert(usage)
        }
        let transcripts = [
            "Thanks for the quick turnaround on this. I reviewed the draft and it looks great, let's ship it on Thursday.",
            "Can you move our sync to 3 PM tomorrow? I want to go through the Q3 roadmap and the launch checklist together.",
            "Reminder to update the onboarding docs with the new Kubernetes setup and the JSON schema changes."
        ]
        for (index, text) in transcripts.enumerated() {
            context.insert(TranscriptHistoryItem(
                transcript: text,
                pasted: true,
                statusMessage: "Pasted",
                durationSeconds: 7,
                createdAt: Date().addingTimeInterval(Double(-index) * 2400 - 300)
            ))
        }
        try context.save()
        return container
    }

    // MARK: - Rendering

    private func renderPage<V: View>(_ view: V, appearance: NSAppearance.Name, name: String) throws {
        var image: NSImage?
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            image = renderer.nsImage
        }
        try write(try XCTUnwrap(image?.tiffRepresentation), name: name)
    }

    private func renderInWindow<V: View>(_ view: V, size: NSSize, name: String) throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        try write(try XCTUnwrap(rep.tiffRepresentation), name: name)
    }

    private func write(_ tiff: Data, name: String) throws {
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }
}

@MainActor
private final class ReadyTranscriber: Transcribing {
    func transcribe(_ audio: RecordedAudio, settings: AppSettings, vocabulary: [String]) async throws -> String { "" }
    func modelStatus(settings: AppSettings) -> TranscriptionModelStatus {
        TranscriptionModelStatus(modelName: settings.transcriptionModel, isReady: true, localPath: nil)
    }
    func prepare(settings: AppSettings, progress: ModelPreparationProgress?) async throws {}
    func isLoaded(settings: AppSettings) -> Bool { true }
    func unloadModel() {}
    func deleteDownloadedModels() throws {}
}
