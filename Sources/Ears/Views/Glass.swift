import AppKit
import SwiftUI

/// Translucent black backing — see-through dark theme, no frosted blur.
struct GlassBackground: View {
    var body: some View {
        Color.black.opacity(0.55)
    }
}

/// Grabs the hosting NSWindow and turns it into an always-on-top, draggable,
/// transparent HUD panel that stays visible across every Space and over
/// other apps — including their full-screen windows.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            OverlayWindow.pin(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Intercepts the close button: the HUD hides instead of closing, because
/// SwiftUI destroys a closed window — after which nothing (menu bar, hotkey)
/// could ever bring it back. Every other delegate duty is forwarded to
/// SwiftUI's own delegate untouched.
private final class HideOnCloseDelegate: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original
    }
}

/// Keeps the HUD pinned above everything and re-asserts it whenever the app or
/// another window would otherwise let it drop.
enum OverlayWindow {
    private static weak var pinned: NSWindow?
    private static var observing = false
    private static let closeInterceptor = HideOnCloseDelegate()

    static func pin(_ window: NSWindow) {
        pinned = window
        apply(to: window)
        startObserving()
    }

    static func reassert() {
        guard let window = pinned else { return }
        apply(to: window)
    }

    static var isVisible: Bool {
        pinned?.isVisible ?? false
    }

    static func show() {
        guard !isVisible else { return }
        toggleVisibility()
    }

    /// ⌘⇧E (via GlobalHotKey) hides/shows the HUD.
    static func toggleVisibility() {
        guard let window = pinned else { return }
        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            apply(to: window)
        }
    }

    private static func apply(to window: NSWindow) {
        // Above the menu bar and other apps' floating panels, so it stays
        // visible no matter what is focused.
        window.level = .statusBar
        // Invisible in screen shares and recordings — only the user sees it.
        window.sharingType = .none
        window.collectionBehavior = [
            .canJoinAllSpaces,   // appear on every Space, including other apps'
            .fullScreenAuxiliary, // overlay full-screen spaces
            .stationary,          // don't slide during Space transitions
            .ignoresCycle,        // stay out of window cycling
        ]
        window.isMovableByWindowBackground = true
        // Closing hides rather than destroys — the menu bar item reopens it.
        window.isReleasedWhenClosed = false
        if !(window.delegate is HideOnCloseDelegate) {
            closeInterceptor.original = window.delegate
            window.delegate = closeInterceptor
        }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hidesOnDeactivate = false
        // Full traffic lights: close hides (see HideOnCloseDelegate), minimize
        // and zoom behave normally. Without fullScreenPrimary in the collection
        // behavior, the green button zooms (maximizes) rather than entering
        // full screen — the HUD stays an overlay.
        window.styleMask.insert([.miniaturizable, .resizable])
        window.standardWindowButton(.zoomButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
    }

    private static func startObserving() {
        guard !observing else { return }
        observing = true
        // Some app/Space transitions quietly reset window level — re-pin on
        // every activation and Space change.
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                           object: nil, queue: .main) { _ in reassert() }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                           object: nil, queue: .main) { _ in reassert() }
        // Some transitions fire neither notification (e.g. hopping between
        // two other apps' full-screen Spaces while Ears stays inactive) yet
        // still strip the overlay status. A watchdog catches whatever slips
        // through — same pattern the audio pipeline uses.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            DispatchQueue.main.async { reassertIfDrifted() }
        }
    }

    private static func reassertIfDrifted() {
        guard let window = pinned else { return }
        let wanted: NSWindow.CollectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
        ]
        if window.level != .statusBar
            || !window.collectionBehavior.isSuperset(of: wanted)
            || window.sharingType != .none {
            apply(to: window)
        }
    }
}
