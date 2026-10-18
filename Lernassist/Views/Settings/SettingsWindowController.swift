import SwiftUI
import AppKit

/// Öffnet die Einstellungen als eigenes, größenveränderbares Fenster (genau eine Instanz).
/// Ersetzt das frühere Sheet am schwebenden Hauptpanel: Es war breiter als das Panel und
/// Sheets an einem NSPanel waren bereits Ursache eines App-Freezes
/// (DEBUGGING-APP-FREEZE-2026-09-21.md).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(viewModel: ChatViewModel, tab: String?) {
        if let window {
            if let tab {
                NotificationCenter.default.post(name: .debugSwitchSettingsTab, object: nil, userInfo: ["tab": tab])
            }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = SettingsView(viewModel: viewModel, initialTab: tab) { [weak self] in
            self?.window?.close()
        }
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Einstellungen"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 920, height: 640))
        window.contentMinSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        // Das Hauptpanel schwebt (.floating) – die Einstellungen müssen darüber liegen.
        window.level = .floating + 1
        window.delegate = self
        window.setFrameAutosaveName("LernAssistSettingsWindow")
        if !window.setFrameUsingName("LernAssistSettingsWindow") { window.center() }
        self.window = window

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
    }
}
