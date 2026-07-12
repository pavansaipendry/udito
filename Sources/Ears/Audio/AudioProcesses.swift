import CoreAudio
import Foundation

/// Helpers over Core Audio's process objects (macOS 14.4+): every process
/// that produces or consumes audio has one, with PID, bundle ID, and
/// liveness properties.
@available(macOS 14.4, *)
enum AudioProcesses {
    static func processObjects() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &objects) == noErr
        else { return [] }
        return objects
    }

    static func pid(of object: AudioObjectID) -> pid_t? {
        var addr = address(kAudioProcessPropertyPID)
        var value = pid_t(-1)
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func bundleID(of object: AudioObjectID) -> String? {
        var addr = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        guard err == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func isRunningInput(_ object: AudioObjectID) -> Bool {
        var addr = address(kAudioProcessPropertyIsRunningInput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    /// Processes actively using the microphone — i.e. the app(s) in a call —
    /// expanded to sibling processes of the same app, because browsers and
    /// Electron apps often split input and output across helper processes.
    static func inCallProcessObjects(excludingPID excluded: pid_t) -> [AudioObjectID] {
        let all = processObjects()
        var selected: Set<AudioObjectID> = []
        var callerBundles: [String] = []

        for object in all {
            guard isRunningInput(object), pid(of: object) != excluded else { continue }
            selected.insert(object)
            if let bundle = bundleID(of: object), !bundle.isEmpty {
                callerBundles.append(bundle)
            }
        }
        guard !selected.isEmpty else { return [] }

        for object in all where !selected.contains(object) {
            guard let bundle = bundleID(of: object), !bundle.isEmpty else { continue }
            if callerBundles.contains(where: { isRelated($0, bundle) }) {
                selected.insert(object)
            }
        }
        return Array(selected)
    }

    /// "com.google.Chrome.helper" and "com.google.Chrome" belong together.
    private static func isRelated(_ a: String, _ b: String) -> Bool {
        a == b || a.hasPrefix(b + ".") || b.hasPrefix(a + ".")
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
