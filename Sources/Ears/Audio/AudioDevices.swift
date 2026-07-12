import CoreAudio
import Foundation

/// Thin Core Audio HAL helpers: device enumeration, UIDs, default devices.
enum AudioDevices {
    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    static func name(of id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioObjectPropertyName)
    }

    static func uid(of id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        guard err == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func inputChannelCount(of id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        deviceProperty(kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        deviceProperty(kAudioHardwarePropertyDefaultInputDevice)
    }

    private static func deviceProperty(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var addr = address(selector)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    @discardableResult
    static func setDefaultOutputDevice(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = id
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &device
        ) == noErr
    }

    static func findDevice(named substring: String, needsInput: Bool = false) -> AudioDeviceID? {
        allDeviceIDs().first { id in
            guard let deviceName = name(of: id),
                  deviceName.localizedCaseInsensitiveContains(substring) else { return false }
            return !needsInput || inputChannelCount(of: id) > 0
        }
    }

    static func findDevice(uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { self.uid(of: $0) == uid }
    }

    static func transportType(of id: AudioDeviceID) -> UInt32 {
        var addr = address(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    /// Loopback drivers (BlackHole, Teams Audio) and aggregates — never a real mic.
    static func isVirtual(_ id: AudioDeviceID) -> Bool {
        let transport = transportType(of: id)
        return transport == kAudioDeviceTransportTypeVirtual
            || transport == kAudioDeviceTransportTypeAggregate
    }

    static func builtInInputDeviceID() -> AudioDeviceID? {
        allDeviceIDs().first {
            inputChannelCount(of: $0) > 0 && transportType(of: $0) == kAudioDeviceTransportTypeBuiltIn
        }
    }

    /// The device to transcribe the user's voice from: the default input,
    /// unless that's a virtual loopback — then fall back to the built-in mic.
    static func bestMicrophoneID() -> AudioDeviceID? {
        if let def = defaultInputDeviceID(), inputChannelCount(of: def) > 0, !isVirtual(def) {
            return def
        }
        return builtInInputDeviceID() ?? defaultInputDeviceID()
    }
}
