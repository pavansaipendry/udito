import AVFoundation
import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

/// Common surface for anything that captures the meeting's system audio.
protocol SystemAudioSource: AnyObject {
    var onAudio: ((Data) -> Void)? { get set }
    var onLevel: ((Float) -> Void)? { get set }
    var isStalled: Bool { get }
    func start() throws
    func stop()
    func tryRestart()
}

/// Driverless system-audio capture via a Core Audio process tap
/// (macOS 14.4+). Captures the mixdown of everything the Mac plays — no
/// BlackHole install, no output-device switching, volume keys keep working,
/// and it follows the user across output devices automatically. The tap and
/// its aggregate are private, so nothing shows up in Sound settings and the
/// OS tears both down if the process dies.
@available(macOS 14.4, *)
final class ProcessTapCapture: SystemAudioSource {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioDeviceID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private let captureQueue = DispatchQueue(label: "ears.systemtap")
    // All tap lifecycle (create/destroy device + tap) runs here, never on the
    // main thread — Core Audio HAL calls can stall for seconds and would
    // otherwise beachball the UI.
    private let controlQueue = DispatchQueue(label: "ears.systemtap.control")
    private let converter = PCMConverter()
    private let stateLock = NSLock()
    private var _lastBufferAt: Date?
    private var running = false
    private var tappedProcessObjects: Set<AudioObjectID> = []

    var onAudio: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?

    deinit { stop() }

    var lastBufferAt: Date? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _lastBufferAt
    }

    var isStalled: Bool {
        guard running, let last = lastBufferAt else { return false }
        return Date().timeIntervalSince(last) > 5
    }

    // MARK: - Lifecycle

    /// Initial start is synchronous so SessionController can catch a failure
    /// and fall back to BlackHole — but the Core Audio work still runs on the
    /// control queue, serialized against any later restart.
    func start() throws {
        running = true
        var thrown: Error?
        controlQueue.sync {
            do {
                try startTap()
            } catch {
                thrown = error
            }
        }
        if let thrown {
            running = false
            throw thrown
        }
    }

    func stop() {
        running = false
        controlQueue.sync { stopTap() }
    }

    /// Watchdog stall recovery — async so it can never block the main thread.
    func tryRestart() {
        guard running else { return }
        controlQueue.async { [weak self] in
            guard let self, self.running else { return }
            EarsLog.info("[system-tap] restarting capture: stalled — no audio for 5s")
            self.stopTap()
            do {
                try self.startTap()
            } catch {
                EarsLog.error("[system-tap] restart failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Tap plumbing

    private var smartTargetingEnabled: Bool {
        UserDefaults.standard.object(forKey: "smartTapTargeting") as? Bool ?? true
    }

    private func currentCallRoster() -> [AudioObjectID] {
        guard smartTargetingEnabled else { return [] }
        return AudioProcesses.inCallProcessObjects(excludingPID: ProcessInfo.processInfo.processIdentifier)
    }

    private func makeDescription() -> CATapDescription {
        let inCall = currentCallRoster()
        if inCall.isEmpty {
            // No app is on the mic yet — capture the global mixdown.
            tappedProcessObjects = []
            EarsLog.info("[system-tap] capturing global system mixdown")
            return CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
        // An app is in a call: tap only that app (and its helper processes),
        // so notifications and music apps stay out of the transcript.
        tappedProcessObjects = Set(inCall)
        let names = Set(inCall.compactMap { AudioProcesses.bundleID(of: $0) }).sorted().joined(separator: ", ")
        EarsLog.info("[system-tap] capturing in-call app(s) only: \(names)")
        return CATapDescription(stereoMixdownOfProcesses: inCall)
    }

    private func startTap() throws {
        stopTap()

        // Triggers the one-time "System Audio Recording" permission prompt
        // on first use.
        let description = makeDescription()
        description.name = "Ears System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &newTapID)
        guard err == noErr, newTapID != kAudioObjectUnknown else {
            throw EarsError("System audio tap was refused (error \(err)). Allow Ears under System Settings → Privacy & Security → Screen & System Audio Recording.")
        }
        tapID = newTapID

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        err = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard err == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            stopTap()
            throw EarsError("Could not read the system tap's audio format (error \(err)).")
        }
        tapFormat = format

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Ears Tap Device",
            kAudioAggregateDeviceUIDKey as String: "com.pavansai.ears.tap",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: true,
                ],
            ],
        ]
        var newAggregateID = AudioDeviceID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard err == noErr, newAggregateID != kAudioObjectUnknown else {
            stopTap()
            throw EarsError("Could not create the tap capture device (error \(err)).")
        }
        aggregateID = newAggregateID

        err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, captureQueue) { [weak self] _, inInputData, _, _, _ in
            self?.handle(inInputData)
        }
        guard err == noErr, ioProcID != nil else {
            stopTap()
            throw EarsError("Could not attach to the tap capture device (error \(err)).")
        }

        err = AudioDeviceStart(aggregateID, ioProcID)
        guard err == noErr else {
            stopTap()
            throw EarsError("Could not start the tap capture device (error \(err)).")
        }

        stateLock.lock()
        _lastBufferAt = Date()
        stateLock.unlock()
        EarsLog.info("[system-tap] capture started (\(Int(format.sampleRate)) Hz, \(format.channelCount) ch)")
    }

    private func stopTap() {
        if let procID = ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioDeviceID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Render path (realtime queue)

    private func handle(_ bufferList: UnsafePointer<AudioBufferList>) {
        guard let format = tapFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: bufferList, deallocator: nil),
              buffer.frameLength > 0 else { return }

        stateLock.lock()
        _lastBufferAt = Date()
        stateLock.unlock()

        if let level = Self.level(of: buffer) {
            onLevel?(level)
        }
        if let data = converter.convert(buffer), !data.isEmpty {
            onAudio?(data)
        }
    }

    /// RMS mapped from [-50 dBFS, 0 dBFS] to [0, 1].
    private static func level(of buffer: AVAudioPCMBuffer) -> Float? {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        let sampleCount = vDSP_Length(buffer.frameLength) * vDSP_Length(max(buffer.format.isInterleaved ? buffer.format.channelCount : 1, 1))
        var rms: Float = 0
        vDSP_rmsqv(channels[0], 1, &rms, sampleCount)
        let db = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (db + 50) / 50))
    }
}

extension HALCapture: SystemAudioSource {}
