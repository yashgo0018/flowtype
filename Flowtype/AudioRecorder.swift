import AVFoundation
import CoreAudio
import Foundation

/// 16 kHz mono PCM captured from the microphone.
struct RecordedAudio: Sendable {
    static let sampleRate: Double = 16_000

    let samples: [Float]
    let peakLevel: Float

    var duration: TimeInterval { Double(samples.count) / Self.sampleRate }

    /// 16-bit PCM WAV encoding, used for cloud transcription uploads.
    func wavData() -> Data {
        let sampleRate = UInt32(Self.sampleRate)
        let bytesPerSample: UInt16 = 2
        let dataSize = UInt32(samples.count) * UInt32(bytesPerSample)
        var data = Data(capacity: 44 + Int(dataSize))

        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(sampleRate)
        append(sampleRate * UInt32(bytesPerSample))
        append(bytesPerSample)
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            append(Int16(clamped * Float(Int16.max)))
        }
        return data
    }
}

enum AudioCaptureError: LocalizedError {
    case noInputDevice
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone is available."
        case .converterUnavailable: "The microphone's audio format isn't supported."
        }
    }
}

protocol AudioCapturing: AnyObject {
    var isRecording: Bool { get }
    /// Normalized 0...1 input level, delivered on the main queue while recording.
    var onLevel: (@MainActor (Float) -> Void)? { get set }
    /// Called on the main queue if the input device disappears or changes mid-recording.
    var onInterruption: (@MainActor () -> Void)? { get set }
    func start(deviceUID: String?) throws
    func stop() -> RecordedAudio?
    func cancel()
}

final class AudioRecorder: AudioCapturing, @unchecked Sendable {
    var onLevel: (@MainActor (Float) -> Void)?
    var onInterruption: (@MainActor () -> Void)?

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    // Guarded by `lock`: written from the audio thread, read from the main thread.
    private var samples: [Float] = []
    private var peak: Float = 0
    private var capturing = false

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: RecordedAudio.sampleRate,
        channels: 1,
        interleaved: false
    )!

    var isRecording: Bool {
        lock.withLock { capturing }
    }

    func start(deviceUID: String?) throws {
        guard !isRecording else { return }

        // A fresh engine per recording picks up the current default input device.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let deviceUID, !deviceUID.isEmpty, let deviceID = AudioDevices.deviceID(forUID: deviceUID) {
            AudioDevices.setInputDevice(deviceID, on: input)
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioCaptureError.converterUnavailable
        }
        converter.downmix = true

        // Capture from the very first buffer so the start of the first word isn't lost.
        lock.withLock {
            samples = []
            samples.reserveCapacity(Int(RecordedAudio.sampleRate) * 60)
            peak = 0
            capturing = true
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer, converter: converter)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.withLock { capturing = false }
            throw error
        }

        self.engine = engine
        let startedAt = Date()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Selecting a specific input device can report a change right after starting.
                guard let self, self.isRecording, Date().timeIntervalSince(startedAt) > 0.5 else { return }
                self.onInterruption?()
            }
        }
    }

    func stop() -> RecordedAudio? {
        guard isRecording else { return nil }
        tearDownEngine()
        return lock.withLock {
            capturing = false
            let audio = RecordedAudio(samples: samples, peakLevel: peak)
            samples = []
            return audio
        }
    }

    func cancel() {
        tearDownEngine()
        lock.withLock {
            capturing = false
            samples = []
            peak = 0
        }
    }

    private func tearDownEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    /// Runs on the audio render thread.
    private func process(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        let supplied = SuppliedFlag()
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied.value {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied.value = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = output.floatChannelData?[0] else { return }

        let frames = Int(output.frameLength)
        guard frames > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel, count: frames))
        var sumSquares: Float = 0
        var chunkPeak: Float = 0
        for sample in chunk {
            sumSquares += sample * sample
            chunkPeak = max(chunkPeak, abs(sample))
        }

        let stillCapturing = lock.withLock { () -> Bool in
            guard capturing else { return false }
            samples.append(contentsOf: chunk)
            peak = max(peak, chunkPeak)
            return true
        }
        guard stillCapturing else { return }

        let rms = sqrt(sumSquares / Float(frames))
        let level = Self.normalizedLevel(rms: rms)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.onLevel?(level)
            }
        }
    }

    /// Maps RMS to 0...1 on a -55 dB...-10 dB scale, which matches speech at typical mic distance.
    private static func normalizedLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return max(0, min(1, (decibels + 55) / 45))
    }
}

private final class SuppliedFlag: @unchecked Sendable {
    var value = false
}

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let uid: String
    let name: String

    var id: String { uid }
}

enum AudioDevices {
    static func inputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasInputStreams(id),
                  let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, selector: kAudioObjectPropertyName) else {
                return nil
            }
            return AudioInputDevice(uid: uid, name: name)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { stringProperty($0, selector: kAudioDevicePropertyDeviceUID) == uid && hasInputStreams($0) }
    }

    static func setInputDevice(_ deviceID: AudioDeviceID, on input: AVAudioInputNode) {
        guard let unit = input.audioUnit else { return }
        var device = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            NSLog("Flowtype could not select input device \(deviceID): \(status)")
        }
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func stringProperty(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
