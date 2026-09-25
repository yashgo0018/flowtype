import AppKit
import Combine
import SwiftUI

@MainActor
final class FlowBarModel: ObservableObject {
    @Published var isHovering = false
    /// Size of the visible pill. SwiftUI animates the pill to this size inside the panel.
    @Published var pillSize = CGSize(width: 44, height: 10)
}

@MainActor
final class FlowBarPanelController {
    /// Transparent space around the pill for its shadow.
    static let margin: CGFloat = 14

    private let controller: AppStateController
    private let model = FlowBarModel()
    private let panel: FlowBarPanel
    private var cancellables: Set<AnyCancellable> = []
    private var currentScreen: NSScreen?
    private var wasRecording = false
    private var shrinkTask: Task<Void, Never>?
    private var hoverTimer: Timer?
    private var pointerLeftAt: Date?

    init(controller: AppStateController) {
        self.controller = controller
        let rootView = FlowBarView()
            .environmentObject(controller)
            .environmentObject(controller.levelMeter)
            .environmentObject(model)
        let hostingView = FlowBarHostingView(rootView: rootView)
        // The panel's frame is set only by this controller. By default SwiftUI also resizes the window
        // to fit its content, which fought the hover animation and made the pill flicker.
        hostingView.sizingOptions = []
        panel = FlowBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hostingView.onHoverChange = { [weak self] hovering in
            self?.hoverChanged(hovering)
        }
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none

        Publishers.CombineLatest4(controller.$phase, controller.$settings, controller.$modelActivity, model.$isHovering)
            .receive(on: RunLoop.main)
            .sink { [weak self] phase, settings, activity, hovering in
                self?.update(phase: phase, settings: settings, activity: activity, hovering: hovering)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.currentScreen = nil
                self.update(phase: controller.phase, settings: controller.settings, activity: controller.modelActivity, hovering: self.model.isHovering)
            }
            .store(in: &cancellables)
    }

    // MARK: Hover

    /// Hover is decided by geometry (is the pointer over the visible pill?), re-checked on a short
    /// timer while the pointer is near. Tracking-area events only start the checks, so window
    /// resizes can't produce the expand/collapse loop that enter/exit events alone caused.
    private func hoverChanged(_ entered: Bool) {
        Log.app.debug("Dictation bar pointer \(entered ? "entered" : "exited", privacy: .public) the panel")
        if entered && hoverTimer == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluateHover() }
            }
            RunLoop.main.add(timer, forMode: .common)
            hoverTimer = timer
        }
        evaluateHover()
    }

    private func evaluateHover() {
        let pointer = NSEvent.mouseLocation
        if pillRect().insetBy(dx: -6, dy: -6).contains(pointer) {
            pointerLeftAt = nil
            if !model.isHovering { model.isHovering = true }
            return
        }
        if model.isHovering {
            // Collapse only after the pointer has stayed off the pill briefly.
            let leftAt = pointerLeftAt ?? Date()
            pointerLeftAt = leftAt
            guard Date().timeIntervalSince(leftAt) >= 0.2 else { return }
            pointerLeftAt = nil
            model.isHovering = false
        }
        if !panel.frame.contains(pointer) {
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
    }

    /// The visible pill in screen coordinates.
    private func pillRect() -> NSRect {
        let frame = panel.frame
        let size = model.pillSize
        let x: CGFloat = switch controller.settings.flowBarPosition {
        case .bottomCenter: frame.midX - size.width / 2
        case .bottomRight: frame.maxX - Self.margin - size.width
        }
        return NSRect(x: x, y: frame.minY + Self.margin, width: size.width, height: size.height)
    }

    func show() {
        update(phase: controller.phase, settings: controller.settings, activity: controller.modelActivity, hovering: false)
    }

    private func update(phase: DictationPhase, settings: AppSettings, activity: ModelActivity?, hovering: Bool) {
        let isIdle = phase == .idle
        if isIdle && !settings.showFlowBarWhenIdle {
            model.isHovering = false
            panel.orderOut(nil)
            return
        }
        // Follow the user to the screen they're working on when a dictation starts.
        if currentScreen == nil || (phase.isRecording && !wasRecording) {
            currentScreen = screenUnderMouse()
        }
        wasRecording = phase.isRecording

        let size = FlowBarLayout.size(phase: phase, activity: activity, hovering: hovering, settings: settings)
        // SwiftUI animates the pill; the panel itself never animates. It grows immediately and shrinks
        // only after the pill has finished shrinking, so the pill never moves under the pointer.
        model.pillSize = size
        let target = frame(for: size, position: settings.flowBarPosition)
        shrinkTask?.cancel()
        guard panel.isVisible else {
            panel.setFrame(target, display: true)
            panel.orderFrontRegardless()
            return
        }
        let current = panel.frame
        if target.width >= current.width && target.height >= current.height {
            panel.setFrame(target, display: true)
            return
        }
        let roomy = CGSize(
            width: max(size.width, current.width - Self.margin * 2),
            height: max(size.height, current.height - Self.margin * 2)
        )
        panel.setFrame(frame(for: roomy, position: settings.flowBarPosition), display: true)
        shrinkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else { return }
            self.panel.setFrame(target, display: true)
        }
    }

    private func frame(for size: CGSize, position: FlowBarPosition) -> NSRect {
        let screen = currentScreen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = size.width + Self.margin * 2
        let height = size.height + Self.margin * 2
        let x: CGFloat
        switch position {
        case .bottomCenter:
            x = visible.midX - width / 2
        case .bottomRight:
            x = visible.maxX - width - 12
        }
        return NSRect(x: x.rounded(), y: visible.minY + 6, width: width, height: height)
    }

    private func screenUnderMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
    }
}

@MainActor
enum FlowBarLayout {
    static func size(phase: DictationPhase, activity: ModelActivity?, hovering: Bool, settings: AppSettings) -> CGSize {
        switch phase {
        case .idle:
            return hovering ? CGSize(width: idleHintWidth(settings: settings), height: 36) : CGSize(width: 44, height: 10)
        case .recording:
            return CGSize(width: 232, height: 40)
        case .transcribing:
            return activity == nil ? CGSize(width: 150, height: 40) : CGSize(width: 250, height: 40)
        case .finished(let feedback):
            let titleWidth = textWidth(feedback.title, weight: .semibold, size: 13)
            let detailWidth = feedback.detail.map { textWidth($0, weight: .regular, size: 11) } ?? 0
            let width = min(380, max(150, max(titleWidth, detailWidth) + 64))
            return CGSize(width: width.rounded(.up), height: feedback.detail == nil ? 40 : 50)
        }
    }

    static func idleHintWidth(settings: AppSettings) -> CGFloat {
        // Text plus the mic and open buttons on either side.
        min(400, textWidth(FlowBarView.idleHint(settings: settings), weight: .medium, size: 12) + 104)
    }

    private static func textWidth(_ text: String, weight: NSFont.Weight, size: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

final class FlowBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FlowBarHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Added once: .inVisibleRect follows the view as the panel resizes. Recreating the area on
        // every resize posts a spurious mouseExited, which made the pill expand and collapse in a loop.
        guard trackingArea == nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // SwiftUI routes its own tracking areas (button hover, tooltips) through these methods too;
    // only the panel-wide area decides whether the pill is hovered.
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard event.trackingArea === trackingArea else { return }
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard event.trackingArea === trackingArea else { return }
        onHoverChange?(false)
    }
}

// MARK: - Views

struct FlowBarView: View {
    @EnvironmentObject private var controller: AppStateController
    @EnvironmentObject private var model: FlowBarModel

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.16), Color(white: 0.07)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 1)
                )

            content
                .padding(.horizontal, isCollapsed ? 0 : 6)
                .transition(.opacity)
        }
        .frame(width: model.pillSize.width, height: model.pillSize.height)
        .clipShape(Capsule(style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: model.pillSize)
        .contextMenu {
            Button("Open Flowtype") { controller.showHub(.home) }
            Button("History") { controller.showHub(.history) }
            Button("Settings…") { controller.showHub(.settings) }
            Divider()
            Button("Quit Flowtype") { NSApp.terminate(nil) }
        }
        .padding(FlowBarPanelController.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: pillAlignment)
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.18), value: stateKey)
    }

    private var pillAlignment: Alignment {
        controller.settings.flowBarPosition == .bottomRight ? .bottomTrailing : .bottom
    }

    private var isCollapsed: Bool {
        controller.phase == .idle && !model.isHovering
    }

    private var stateKey: String {
        switch controller.phase {
        case .idle: model.isHovering ? "hover" : "idle"
        case .recording: "recording"
        case .transcribing: "transcribing"
        case .finished(let feedback): feedback.id.uuidString
        }
    }

    private var borderColor: Color {
        switch controller.phase {
        case .recording: Color.red.opacity(0.55)
        case .finished(let feedback) where feedback.kind == .error: Color.red.opacity(0.4)
        default: Color.white.opacity(model.isHovering ? 0.28 : 0.18)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle:
            if model.isHovering {
                IdleHintView()
            }
        case .recording(let mode, let startedAt):
            RecordingView(mode: mode, startedAt: startedAt)
        case .transcribing:
            TranscribingView(activity: controller.modelActivity)
        case .finished(let feedback):
            FeedbackView(feedback: feedback)
        }
    }

    static func idleHint(settings: AppSettings) -> String {
        let toggle = ShortcutParser.display(settings.toggleShortcut)
        switch settings.holdKey {
        case .off: return "Click or press \(toggle) to dictate"
        default: return "Hold \(settings.holdKey.symbol) or press \(toggle) to dictate"
        }
    }
}

private struct IdleHintView: View {
    @EnvironmentObject private var controller: AppStateController

    var body: some View {
        HStack(spacing: 8) {
            FlowBarIconButton(systemImage: "mic.fill", tint: .white, background: .accentColor, help: "Start dictating") {
                controller.toggleFromFlowBar()
            }
            if !controller.needsSetup {
                Text(FlowBarView.idleHint(settings: controller.settings))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            } else {
                Button {
                    controller.showHub(.home)
                } label: {
                    Text("Finish setup to start dictating")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            FlowBarIconButton(systemImage: "slider.horizontal.3", tint: .white.opacity(0.85), background: .white.opacity(0.12), help: "Open Flowtype") {
                controller.showHub()
            }
        }
        .padding(.horizontal, 2)
    }
}

private struct RecordingView: View {
    @EnvironmentObject private var controller: AppStateController
    let mode: RecordingMode
    let startedAt: Date

    var body: some View {
        HStack(spacing: 10) {
            FlowBarIconButton(systemImage: "xmark", tint: .white.opacity(0.85), background: .white.opacity(0.12), help: "Cancel (Esc)") {
                controller.cancel()
            }
            WaveformView()
                .frame(maxWidth: .infinity)
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(Self.elapsed(from: startedAt, to: context.date))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
            }
            FlowBarIconButton(systemImage: "stop.fill", tint: .white, background: .red, help: mode == .pushToTalk ? "Release the key to finish" : "Finish") {
                controller.stopRecording()
            }
        }
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct WaveformView: View {
    @EnvironmentObject private var meter: AudioLevelMeter

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(meter.levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color.white.opacity(0.55 + Double(level) * 0.45))
                    .frame(width: 2.5, height: 3 + CGFloat(level) * 18)
            }
        }
        .frame(height: 22)
        .animation(.linear(duration: 0.08), value: meter.levels)
    }
}

private struct TranscribingView: View {
    let activity: ModelActivity?

    var body: some View {
        HStack(spacing: 10) {
            PulsingDots()
            switch activity {
            case .downloading(let fraction):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Downloading model \(Int(fraction * 100))%")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .frame(height: 3)
                }
            case .loading:
                Text("Loading model…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            case nil:
                Text("Transcribing")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
    }
}

private struct PulsingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    let phase = sin(time * 5 - Double(index) * 0.8)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 6, height: 6)
                        .opacity(0.35 + 0.65 * (phase + 1) / 2)
                        .scaleEffect(0.75 + 0.25 * (phase + 1) / 2)
                }
            }
        }
    }
}

private struct FeedbackView: View {
    @EnvironmentObject private var controller: AppStateController
    let feedback: Feedback

    var body: some View {
        Button {
            if let action = feedback.action {
                controller.perform(action)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(feedback.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    if let detail = feedback.detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(feedback.action != nil)
    }

    private var icon: String {
        switch feedback.kind {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch feedback.kind {
        case .success: .green
        case .info: .white.opacity(0.8)
        case .warning: .orange
        case .error: .red
        }
    }
}

private struct FlowBarIconButton: View {
    let systemImage: String
    let tint: Color
    let background: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(background, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
