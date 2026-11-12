import AVFoundation
import CoreAudio
import Foundation

@MainActor
protocol MeetingCapturing: AnyObject {
    var onFailure: ((String) -> Void)? { get set }
    func start(queue: MeetingAudioQueue, origin: Double, microphoneUID: String) async throws
    func stop()
}

/// Audio-only Core Audio process tap. Does not change the default output or capture video.
@MainActor
final class MeetingCapture: MeetingCapturing {
    var onFailure: ((String) -> Void)?
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var generation = UUID()
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var hardwareListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private let ioQueue = DispatchQueue(label: "io.flowtype.meeting.system", qos: .userInitiated)

    func start(queue: MeetingAudioQueue, origin: Double, microphoneUID: String) async throws {
        guard #available(macOS 14.2, *) else {
            throw MeetingError.message("Meeting capture requires macOS 14.2 or later for audio-only system recording. Dictation remains available.")
        }
        generation = UUID()
        let activeGeneration = generation
        do {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            if !microphoneUID.isEmpty {
                guard let id = AudioDevices.deviceID(forUID: microphoneUID) else { throw AudioCaptureError.noInputDevice }
                AudioDevices.setInputDevice(id, on: input)
            }
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioCaptureError.noInputDevice }
            let callback = try Self.microphoneCallback(format: format, queue: queue, origin: origin)
            try startSystem(queue: queue, origin: origin)
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: callback)
            self.engine = engine
            try engine.start()
            let started = Date()
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard self?.generation == activeGeneration, Date().timeIntervalSince(started) > 1 else { return }
                    self?.onFailure?("Microphone configuration changed. Capture stopped; check your input device before restarting.")
                }
            }
        } catch {
            stop()
            throw error
        }
    }

    @available(macOS 14.2, *)
    private func startSystem(queue: MeetingAudioQueue, origin: Double) throws {
        // Translate our PID to the HAL process object so Flowtype's own sounds are excluded.
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var process: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let translated = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process)
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: translated == noErr && process != 0 ? [process] : [])
        description.name = "Flowtype meeting audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        if #available(macOS 26, *), let bundleID = Bundle.main.bundleIdentifier { description.bundleIDs = [bundleID] }
        try check(AudioHardwareCreateProcessTap(description, &tap), "Create system audio tap")
        address.mSelector = kAudioTapPropertyFormat
        var asbd = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd), "Read system audio format")
        guard let format = AVAudioFormat(streamDescription: &asbd), format.sampleRate > 0 else { throw AudioCaptureError.converterUnavailable }
        let callback = try Self.systemCallback(format: format, queue: queue, origin: origin)
        let configuration: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Flowtype private capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                             kAudioSubTapDriftCompensationKey: true]]
        ]
        try check(AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &aggregate), "Create audio capture device")
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, ioQueue, callback), "Install system audio callback")
        try check(AudioDeviceStart(aggregate, ioProc), "Start system audio (allow System Audio Recording in Privacy & Security)")
        observeHardware(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice)
        observeHardware(tap, selector: kAudioTapPropertyFormat)
    }

    // Audio callbacks must not inherit the capture controller’s MainActor isolation.
    // Their captured converter is confined to one audio queue; the inbox synchronizes access.
    nonisolated static func microphoneCallback(format: AVAudioFormat, queue: MeetingAudioQueue, origin: Double) throws -> AVAudioNodeTapBlock {
        let converter = try MeetingPCMConverter(format: format)
        return { @Sendable buffer, time in
            let start = Self.sessionStart(hostTime: time.isHostTimeValid ? time.hostTime : nil, origin: origin)
            converter.consume(buffer, source: .microphone, at: start, into: queue)
        }
    }

    nonisolated static func systemCallback(format: AVAudioFormat, queue: MeetingAudioQueue, origin: Double) throws -> AudioDeviceIOBlock {
        let converter = try MeetingPCMConverter(format: format)
        return { @Sendable _, input, inputTime, _, _ in
            let stamp = inputTime.pointee
            let start = Self.sessionStart(hostTime: stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : nil, origin: origin)
            converter.consume(input, source: .system, at: start, into: queue)
        }
    }

    nonisolated private static func sessionStart(hostTime: UInt64?, origin: Double) -> Double {
        if let hostTime { return AVAudioTime.seconds(forHostTime: hostTime) - origin }
        return ProcessInfo.processInfo.systemUptime - origin
    }

    private func observeHardware(_ object: AudioObjectID, selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let activeGeneration = generation
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard self?.generation == activeGeneration else { return }
                self?.onFailure?("System output device or audio format changed. Capture stopped; check the output before restarting.")
            }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, listener) == noErr {
            hardwareListeners.append((object, address, listener))
        }
    }

    private func check(_ result: OSStatus, _ operation: String) throws {
        guard result == noErr else { throw MeetingError.message("\(operation) failed (\(result)). No complete recording was made.") }
    }

    func stop() {
        generation = UUID()
        for (object, var address, listener) in hardwareListeners {
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, listener)
        }
        hardwareListeners = []
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        engine = nil
        if aggregate != 0 {
            if let ioProc { AudioDeviceStop(aggregate, ioProc); AudioDeviceDestroyIOProcID(aggregate, ioProc) }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        ioProc = nil
        aggregate = 0
        if #available(macOS 14.2, *), tap != 0 { AudioHardwareDestroyProcessTap(tap) }
        tap = 0
    }
}

/// One instance per source; invoked serially by that source's callback only.
final class MeetingPCMConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let sourceFormat: AVAudioFormat
    init(format source: AVAudioFormat) throws {
        sourceFormat = source
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: RecordedAudio.sampleRate, channels: 1, interleaved: false)!
        guard let value = AVAudioConverter(from: source, to: format) else { throw AudioCaptureError.converterUnavailable }
        converter = value
        converter.downmix = true
    }
    func consume(_ input: UnsafePointer<AudioBufferList>, source: MeetingSource, at start: Double, into queue: MeetingAudioQueue) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, bufferListNoCopy: input, deallocator: nil) else {
            queue.report("System audio buffer format was invalid.", at: start)
            return
        }
        consume(buffer, source: source, at: start, into: queue)
    }

    func consume(_ input: AVAudioPCMBuffer, source: MeetingSource, at start: Double, into queue: MeetingAudioQueue) {
        guard input.frameLength > 0, input.frameLength <= 65_536 else { queue.report("Invalid \(source.title) buffer dropped.", at: start); return }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * format.sampleRate / input.format.sampleRate) + 1024
        guard capacity < 65_536, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        if status == .error { queue.report("\(source.title) sample conversion failed; audio is missing.", at: start); return }
        guard let data = output.floatChannelData?[0] else { return }
        queue.append(Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength))), source: source, at: max(0, start))
    }
}
