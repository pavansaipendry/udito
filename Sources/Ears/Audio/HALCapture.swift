import AVFoundation
import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

/// Captures PCM from one specific audio device via a raw AUHAL unit and
/// delivers 16 kHz mono Int16 chunks plus a level reading.
///
/// Deliberately NOT AVAudioEngine: its inputNode tracks the system default
/// input and silently overrides device pinning on modern macOS, producing an
/// endless configuration-change restart storm. AUHAL pins cleanly and stays
/// pinned for hours.
final class HALCapture {
    private(set) var deviceID: AudioDeviceID
    private let name: String
    private var unit: AudioComponentInstance?
    private var clientFormat: AVAudioFormat?
    private var renderBuffer: AVAudioPCMBuffer?
    private let converter = PCMConverter()
    private let stateLock = NSLock()
    private var _lastBufferAt: Date?
    private var running = false

    var onAudio: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?

    init(deviceID: AudioDeviceID, name: String) {
        self.deviceID = deviceID
        self.name = name
    }

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

    // MARK: - Lifecycle (main thread only)

    func start() throws {
        running = true
        try startUnit()
    }

    func stop() {
        running = false
        stopUnit()
    }

    /// Called by the watchdog when buffers stop flowing.
    func tryRestart() {
        guard running else { return }
        EarsLog.info("[\(name)] restarting capture: stalled — no audio for 5s")
        do {
            try startUnit()
        } catch {
            EarsLog.error("[\(name)] capture restart failed: \(error.localizedDescription)")
        }
    }

    /// Moves capture to a different device (e.g. the default mic changed).
    func retarget(to newDevice: AudioDeviceID) {
        guard newDevice != deviceID else { return }
        deviceID = newDevice
        guard running else { return }
        EarsLog.info("[\(name)] retargeting to \(AudioDevices.name(of: newDevice) ?? "device \(newDevice)")")
        do {
            try startUnit()
        } catch {
            EarsLog.error("[\(name)] retarget failed: \(error.localizedDescription)")
        }
    }

    // MARK: - AUHAL plumbing

    private func startUnit() throws {
        stopUnit()

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw EarsError("HAL audio component not found.")
        }
        var newUnit: AudioComponentInstance?
        try check(AudioComponentInstanceNew(component, &newUnit), "create the capture unit")
        guard let au = newUnit else { throw EarsError("Could not create the capture unit.") }
        // From here on, dispose on any failure.
        do {
            var one: UInt32 = 1
            var zero: UInt32 = 0
            let flagSize = UInt32(MemoryLayout<UInt32>.size)
            try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                           kAudioUnitScope_Input, 1, &one, flagSize),
                      "enable capture input")
            try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                           kAudioUnitScope_Output, 0, &zero, flagSize),
                      "disable playback")

            var device = deviceID
            try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                           kAudioUnitScope_Global, 0, &device,
                                           UInt32(MemoryLayout<AudioDeviceID>.size)),
                      "select the capture device")

            // The device dictates rate/channels; AUHAL does not resample.
            var deviceASBD = AudioStreamBasicDescription()
            var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat,
                                           kAudioUnitScope_Input, 1, &deviceASBD, &asbdSize),
                      "read the device format")
            guard deviceASBD.mSampleRate > 0, deviceASBD.mChannelsPerFrame > 0 else {
                throw EarsError("The capture device reports no usable format.")
            }

            guard let format = AVAudioFormat(
                standardFormatWithSampleRate: deviceASBD.mSampleRate,
                channels: deviceASBD.mChannelsPerFrame
            ) else {
                throw EarsError("Unsupported capture format.")
            }
            var clientASBD = format.streamDescription.pointee
            try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                                           kAudioUnitScope_Output, 1, &clientASBD, asbdSize),
                      "set the capture format")

            var callback = AURenderCallbackStruct(
                inputProc: halInputProc,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback,
                                           kAudioUnitScope_Global, 0, &callback,
                                           UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                      "install the capture callback")

            clientFormat = format
            renderBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)

            try check(AudioUnitInitialize(au), "initialize the capture unit")
            try check(AudioOutputUnitStart(au), "start the capture unit")
        } catch {
            AudioComponentInstanceDispose(au)
            throw error
        }

        unit = au
        stateLock.lock()
        _lastBufferAt = Date()
        stateLock.unlock()
        let rate = Int(clientFormat?.sampleRate ?? 0)
        let channels = clientFormat?.channelCount ?? 0
        EarsLog.info("[\(name)] capture started on \(AudioDevices.name(of: deviceID) ?? "device \(deviceID)") (\(rate) Hz, \(channels) ch)")
    }

    private func stopUnit() {
        guard let au = unit else { return }
        unit = nil
        AudioOutputUnitStop(au)
        AudioUnitUninitialize(au)
        AudioComponentInstanceDispose(au)
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else {
            throw EarsError("Could not \(what) (error \(status)).")
        }
    }

    // MARK: - Render path (realtime thread)

    fileprivate func render(
        _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ timeStamp: UnsafePointer<AudioTimeStamp>,
        _ bus: UInt32,
        _ frames: UInt32
    ) -> OSStatus {
        guard let au = unit else { return noErr }
        if renderBuffer == nil || frames > renderBuffer!.frameCapacity {
            guard let format = clientFormat,
                  let fresh = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 4096)) else {
                return noErr
            }
            renderBuffer = fresh
        }
        guard let buffer = renderBuffer else { return noErr }
        buffer.frameLength = frames

        let status = AudioUnitRender(au, flags, timeStamp, bus, frames, buffer.mutableAudioBufferList)
        guard status == noErr else { return status }

        stateLock.lock()
        _lastBufferAt = Date()
        stateLock.unlock()

        if let level = Self.level(of: buffer) {
            onLevel?(level)
        }
        if let data = converter.convert(buffer), !data.isEmpty {
            onAudio?(data)
        }
        return noErr
    }

    /// RMS mapped from [-50 dBFS, 0 dBFS] to [0, 1].
    private static func level(of buffer: AVAudioPCMBuffer) -> Float? {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        var rms: Float = 0
        vDSP_rmsqv(channels[0], 1, &rms, vDSP_Length(buffer.frameLength))
        let db = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (db + 50) / 50))
    }
}

private func halInputProc(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let capture = Unmanaged<HALCapture>.fromOpaque(inRefCon).takeUnretainedValue()
    return capture.render(ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames)
}
