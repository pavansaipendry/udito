import AVFoundation
import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

/// Microphone capture through Apple's voice-processing IO unit — the same
/// echo canceller FaceTime uses — so the mic stops re-hearing the meeting
/// when the user is on speakers.
///
/// Experimental and opt-in (Settings → Echo cancellation, default off).
/// SessionController falls back to the plain `HALCapture` mic path if this
/// unit fails to start, so the default experience can never regress.
final class VoiceProcessedMicCapture: SystemAudioSource {
    private var unit: AudioComponentInstance?
    private var clientFormat: AVAudioFormat?
    private var renderBuffer: AVAudioPCMBuffer?
    private let converter = PCMConverter()
    private let stateLock = NSLock()
    private var _lastBufferAt: Date?
    private var running = false

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

    // MARK: - Lifecycle (main thread only)

    func start() throws {
        running = true
        try startUnit()
    }

    func stop() {
        running = false
        stopUnit()
    }

    func tryRestart() {
        guard running else { return }
        EarsLog.info("[mic-aec] restarting capture: stalled — no audio for 5s")
        stopUnit()
        do {
            try startUnit()
        } catch {
            EarsLog.error("[mic-aec] restart failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Voice-processing unit plumbing

    private func startUnit() throws {
        stopUnit()

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw EarsError("Voice-processing unit not found.")
        }
        var newUnit: AudioComponentInstance?
        try check(AudioComponentInstanceNew(component, &newUnit), "create the voice-processing unit")
        guard let au = newUnit else {
            throw EarsError("Could not create the voice-processing unit.")
        }
        do {
            var one: UInt32 = 1
            var zero: UInt32 = 0
            let flagSize = UInt32(MemoryLayout<UInt32>.size)
            // The voice processor needs both sides live; we render silence to
            // the output so nothing audible changes.
            try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                           kAudioUnitScope_Input, 1, &one, flagSize),
                      "enable the echo-cancelled mic input")
            try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                           kAudioUnitScope_Output, 0, &one, flagSize),
                      "enable the voice-processing playback side")

            // Keep natural mic levels — no auto gain. Best-effort.
            AudioUnitSetProperty(au, kAUVoiceIOProperty_VoiceProcessingEnableAGC,
                                 kAudioUnitScope_Global, 0, &zero, flagSize)

            // Don't duck the meeting audio while voice processing runs.
            if #available(macOS 14.0, *) {
                var ducking = AUVoiceIOOtherAudioDuckingConfiguration(
                    mEnableAdvancedDucking: false,
                    mDuckingLevel: .min
                )
                AudioUnitSetProperty(au, kAUVoiceIOProperty_OtherAudioDuckingConfiguration,
                                     kAudioUnitScope_Global, 0, &ducking,
                                     UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size))
            }

            var deviceASBD = AudioStreamBasicDescription()
            var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat,
                                           kAudioUnitScope_Input, 1, &deviceASBD, &asbdSize),
                      "read the mic format")

            let sampleRate = deviceASBD.mSampleRate > 0 ? deviceASBD.mSampleRate : 48_000
            let channels = min(max(deviceASBD.mChannelsPerFrame, 1), 2)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) else {
                throw EarsError("Unsupported echo-cancelled mic format.")
            }
            var clientASBD = format.streamDescription.pointee
            try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                                           kAudioUnitScope_Output, 1, &clientASBD, asbdSize),
                      "set the echo-cancelled mic format")

            var inputCallback = AURenderCallbackStruct(
                inputProc: vpioInputProc,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback,
                                           kAudioUnitScope_Global, 0, &inputCallback,
                                           UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                      "install the mic callback")

            var renderCallback = AURenderCallbackStruct(
                inputProc: vpioSilenceProc,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try check(AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback,
                                           kAudioUnitScope_Input, 0, &renderCallback,
                                           UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                      "install the silence renderer")

            clientFormat = format
            renderBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)

            try check(AudioUnitInitialize(au), "initialize the voice-processing unit")
            try check(AudioOutputUnitStart(au), "start the voice-processing unit")
        } catch {
            AudioComponentInstanceDispose(au)
            throw error
        }

        unit = au
        stateLock.lock()
        _lastBufferAt = Date()
        stateLock.unlock()
        let rate = Int(clientFormat?.sampleRate ?? 0)
        EarsLog.info("[mic-aec] echo-cancelled mic started (\(rate) Hz)")
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

        if let channels = buffer.floatChannelData, buffer.frameLength > 0 {
            var rms: Float = 0
            vDSP_rmsqv(channels[0], 1, &rms, vDSP_Length(buffer.frameLength))
            let db = 20 * log10(max(rms, 1e-7))
            onLevel?(max(0, min(1, (db + 50) / 50)))
        }
        if let data = converter.convert(buffer), !data.isEmpty {
            onAudio?(data)
        }
        return noErr
    }
}

private func vpioInputProc(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let capture = Unmanaged<VoiceProcessedMicCapture>.fromOpaque(inRefCon).takeUnretainedValue()
    return capture.render(ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames)
}

private func vpioSilenceProc(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    if let ioData {
        for buffer in UnsafeMutableAudioBufferListPointer(ioData) {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
    }
    return noErr
}
