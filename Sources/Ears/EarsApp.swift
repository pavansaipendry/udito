import AppKit
import Combine
import SwiftUI

@main
struct EarsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var session = SessionController.shared

    var body: some Scene {
        WindowGroup {
            HUDView()
                .environmentObject(session)
                .background(WindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var stateWatcher: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        OutputRouter.cleanUpStale()
        // Accessory agent: no Dock icon, never hidden when other apps activate,
        // and free to float over other apps' full-screen spaces.
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        GlobalHotKey.install()
        setUpStatusItem()
    }

    /// Closing the window hides it; the menu bar ear icon or ⌘⇧E brings it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Safety net: any attempt to reopen the app (e.g. launching it again
    /// from Finder while it's running) shows the HUD.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            OverlayWindow.show()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Restore the user's audio routing even on Cmd-Q mid-session.
        SessionController.shared.emergencyTeardown()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "ear", accessibilityDescription: "Ears")

        let menu = NSMenu()
        menu.delegate = self

        let showHide = NSMenuItem(title: "Show HUD", action: #selector(toggleHUD), keyEquivalent: "e")
        showHide.keyEquivalentModifierMask = [.command, .shift]
        showHide.target = self
        showHide.tag = 2
        menu.addItem(showHide)

        let startStop = NSMenuItem(title: "Start Listening", action: #selector(toggleSession), keyEquivalent: "")
        startStop.target = self
        startStop.tag = 1
        menu.addItem(startStop)

        menu.addItem(.separator())

        let transcripts = NSMenuItem(title: "Open Transcripts Folder", action: #selector(openTranscripts), keyEquivalent: "")
        transcripts.target = self
        menu.addItem(transcripts)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Ears", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // Left-click toggles the HUD directly — the fastest way back in after
        // closing the window. Right-click (or ⌃-click) opens the menu.
        statusMenu = menu
        item.button?.action = #selector(statusItemClicked)
        item.button?.target = self
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        // Live icon: waveform ear while listening.
        stateWatcher = SessionController.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                let symbol = state == .listening ? "ear.badge.waveform" : "ear"
                self?.statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Ears")
            }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: 1)?.title =
            SessionController.shared.state == .idle ? "Start Listening" : "Stop Listening"
        menu.item(withTag: 2)?.title =
            OverlayWindow.isVisible ? "Hide HUD" : "Show HUD"
    }

    /// Left-click restored after the right-click menu closes.
    func menuDidClose(_ menu: NSMenu) {
        statusItem?.menu = nil
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem?.menu = statusMenu
            statusItem?.button?.performClick(nil)
        } else {
            OverlayWindow.toggleVisibility()
        }
    }

    @objc private func toggleSession() {
        SessionController.shared.toggle()
    }

    @objc private func toggleHUD() {
        OverlayWindow.toggleVisibility()
    }

    @objc private func openTranscripts() {
        let directory = SessionController.transcriptsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }
}
