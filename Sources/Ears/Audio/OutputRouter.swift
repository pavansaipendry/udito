import CoreAudio
import Foundation

/// Routes system output through a stacked aggregate (multi-output) device made
/// of the user's real output plus BlackHole, so meeting audio stays audible
/// while the app captures the same stream from BlackHole's input side.
final class OutputRouter {
    static let aggregateUID = "com.pavansai.ears.multiout"

    private(set) var aggregateID: AudioDeviceID?
    private(set) var previousOutputID: AudioDeviceID?

    /// Destroys any aggregate left behind by a crashed session. Bounded: if
    /// coreaudiod refuses the destroy while the device stays enumerable, an
    /// unbounded loop would hang the app at launch.
    static func cleanUpStale() {
        for _ in 0..<5 {
            guard let stale = AudioDevices.findDevice(uid: aggregateUID) else { return }
            guard AudioHardwareDestroyAggregateDevice(stale) == noErr else {
                EarsLog.error("Could not destroy stale multi-output device — continuing anyway")
                return
            }
        }
    }

    func engage(blackHole: AudioDeviceID) throws {
        guard aggregateID == nil else { return }
        guard let current = AudioDevices.defaultOutputDeviceID() else {
            throw EarsError("No default output device found.")
        }
        guard let speakerUID = AudioDevices.uid(of: current),
              let blackHoleUID = AudioDevices.uid(of: blackHole) else {
            throw EarsError("Could not read audio device identifiers.")
        }
        guard speakerUID != blackHoleUID else {
            throw EarsError("Your output device is set to BlackHole itself. Pick your speakers or headphones in Sound settings, then start again.")
        }
        guard speakerUID != Self.aggregateUID else {
            throw EarsError("A stale Ears output device is still active. Pick your speakers in Sound settings, then start again.")
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Ears Meeting Output",
            kAudioAggregateDeviceUIDKey: Self.aggregateUID,
            kAudioAggregateDeviceIsStackedKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: speakerUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: speakerUID],
                [kAudioSubDeviceUIDKey: blackHoleUID,
                 kAudioSubDeviceDriftCompensationKey: 1],
            ],
        ]

        var newID = AudioDeviceID(0)
        let err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newID)
        guard err == noErr, newID != kAudioObjectUnknown else {
            throw EarsError("Could not create the multi-output device (error \(err)).")
        }
        aggregateID = newID
        previousOutputID = current

        // Give coreaudiod a beat to publish the new device before switching.
        usleep(150_000)
        guard AudioDevices.setDefaultOutputDevice(newID) else {
            AudioHardwareDestroyAggregateDevice(newID)
            aggregateID = nil
            previousOutputID = nil
            throw EarsError("Could not switch output to the multi-output device.")
        }
        EarsLog.info("Output routed: \(AudioDevices.name(of: current) ?? "output") + BlackHole")
    }

    func disengage(restore: Bool = true) {
        guard let aggregate = aggregateID else { return }
        if restore,
           let previous = previousOutputID,
           AudioDevices.allDeviceIDs().contains(previous),
           AudioDevices.defaultOutputDeviceID() == aggregate {
            AudioDevices.setDefaultOutputDevice(previous)
            usleep(100_000)
        }
        AudioHardwareDestroyAggregateDevice(aggregate)
        aggregateID = nil
        previousOutputID = nil
        EarsLog.info("Output routing removed")
    }

    /// True while our aggregate is still the system default output.
    var isDefaultOutput: Bool {
        guard let aggregate = aggregateID else { return false }
        return AudioDevices.defaultOutputDeviceID() == aggregate
    }
}
