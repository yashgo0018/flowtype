import AppKit
import SwiftUI

@MainActor
final class FlowBarPanelController {
    private let controller: AppStateController

    private let panel: NSPanel

    init(controller: AppStateController) {
        self.controller = controller
        let rootView = AnyView(FlowBarView().environmentObject(controller))
        let hostingView = FlowBarHostingView(rootView: rootView)
        hostingView.beforeMouseDown = { [weak controller] in
            controller?.preparePasteTargetForFlowBarInteraction()
        }
        panel = FlowBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 82),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovableByWindowBackground = false
    }

    func show() {
        anchor()
        panel.orderFrontRegardless()
    }

    private func anchor() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let x: CGFloat
        switch controller.settings.flowBarPosition {
        case .bottomRight:
            x = frame.maxX - size.width - 24
        case .bottomCenter:
            x = frame.midX - size.width / 2
        }
        panel.setFrameOrigin(NSPoint(x: x, y: frame.minY + 24))
    }
}

final class FlowBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FlowBarHostingView<Content: View>: NSHostingView<Content> {
    var beforeMouseDown: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        beforeMouseDown?()
        super.mouseDown(with: event)
    }
}

struct FlowBarView: View {
    @EnvironmentObject private var controller: AppStateController
    @State private var tick = 0

    var body: some View {
        HStack(spacing: 12) {
            Text(waveform)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 72, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(status)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(primaryTitle) {
                primaryAction()
            }
            .buttonStyle(FlowBarPrimaryButtonStyle(color: primaryColor))

            if isRecording {
                Button("Cancel") {
                    controller.cancelRecording()
                }
                .buttonStyle(FlowBarSecondaryButtonStyle())
            } else {
                Button("Hub") {
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(FlowBarSecondaryButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 360, height: 82)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            tick += 1
        }
    }

    private var status: String {
        switch controller.state {
        case .recording(_, let startedAt):
            let elapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
            return "Recording \(elapsed / 60):\(String(format: "%02d", elapsed % 60))"
        default:
            return controller.state.statusText
        }
    }

    private var hint: String {
        switch controller.state {
        case .recording(let mode, _):
            switch mode {
            case .toggle:
                return "\(ShortcutParser.display(controller.settings.toggleShortcut)) stops - Esc cancels"
            case .hold:
                return "Release \(ShortcutParser.display(controller.settings.holdShortcut)) to stop"
            }
        case .processing:
            return "WhisperKit is processing"
        default:
            return ShortcutParser.display(controller.settings.toggleShortcut)
        }
    }

    private var waveform: String {
        switch controller.state {
        case .recording:
            return tick.isMultiple(of: 2) ? "| || ||| || |" : "|| | ||| | ||"
        case .processing:
            return "- - - - -"
        default:
            return "| || ||| || |"
        }
    }

    private var isRecording: Bool {
        if case .recording = controller.state { return true }
        return false
    }

    private var primaryTitle: String {
        switch controller.state {
        case .recording:
            "Stop"
        case .processing, .pasting:
            "..."
        default:
            "Mic"
        }
    }

    private var primaryColor: Color {
        switch controller.state {
        case .recording:
            .red
        case .processing, .pasting:
            .purple
        case .error:
            .orange
        default:
            .blue
        }
    }

    private func primaryAction() {
        switch controller.state {
        case .recording:
            controller.stopRecording()
        case .processing, .pasting:
            break
        default:
            controller.toggleRecording()
        }
    }
}

struct FlowBarPrimaryButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(color.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct FlowBarSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(.white.opacity(configuration.isPressed ? 0.12 : 0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.white.opacity(0.14))
            )
    }
}
