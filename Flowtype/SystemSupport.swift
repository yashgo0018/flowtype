import AppKit
import ApplicationServices
import AVFoundation
import os

/// Unified logging, viewable in Console.app under the app's subsystem. Transcript text is never logged.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "studio.infinitumlabs.flowtype"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let dictation = Logger(subsystem: subsystem, category: "dictation")
    static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys")
    static let data = Logger(subsystem: subsystem, category: "data")
}

struct PermissionStatus: Equatable {
    var microphone: AVAuthorizationStatus
    var accessibility: Bool

    var microphoneGranted: Bool { microphone == .authorized }
    var allGranted: Bool { microphoneGranted && accessibility }

    static func current() -> PermissionStatus {
        PermissionStatus(
            microphone: PermissionService.microphoneAuthorizationStatus(),
            accessibility: PermissionService.hasAccessibilityPermission()
        )
    }
}

enum PermissionService {
    static func hasAccessibilityPermission(prompt: Bool = false) -> Bool {
        guard prompt else { return AXIsProcessTrusted() }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func microphoneAuthorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Clears a stale Accessibility entry. macOS keeps showing a checked entry after the app is
    /// rebuilt or moved, but the new binary is not trusted until the entry is removed and re-added.
    static func resetAccessibilityPermission() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Log.app.error("Could not reset Accessibility permission: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
enum SoundEffects {
    enum Effect {
        case start
        case stop
        case cancel
        case error

        var name: String {
            switch self {
            case .start: "Tink"
            case .stop: "Pop"
            case .cancel: "Bottle"
            case .error: "Basso"
            }
        }
    }

    private static var cache: [String: NSSound] = [:]

    static func play(_ effect: Effect) {
        let sound = cache[effect.name] ?? NSSound(named: NSSound.Name(effect.name))
        guard let sound else { return }
        cache[effect.name] = sound
        sound.volume = 0.35
        sound.stop()
        sound.play()
    }
}
