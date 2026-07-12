import AppKit
import Carbon.HIToolbox

/// ⌘⇧E shows/hides the HUD from anywhere — no Accessibility permission
/// needed (Carbon hot keys are permission-free, unlike global event
/// monitors).
enum GlobalHotKey {
    private static var hotKeyRef: EventHotKeyRef?
    private static var handlerRef: EventHandlerRef?

    static func install() {
        guard handlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, _ in
                DispatchQueue.main.async { OverlayWindow.toggleVisibility() }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handlerRef
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x4541_5253) /* 'EARS' */, id: 1)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_E),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        if status == noErr {
            EarsLog.info("Global hotkey registered (⌘⇧E toggles the HUD)")
        } else {
            EarsLog.error("Global hotkey registration failed (status \(status))")
        }
    }
}
