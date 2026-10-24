import SwiftUI
import AppKit

/// Transparente, gezielte Griff-Fläche für das schwebende Hauptpanel. Sie ersetzt das breite
/// `isMovableByWindowBackground`, das bei Klicks in modalen SwiftUI-Sheets einen AppKit-
/// Tracking-Loop auslösen kann. Als Hintergrund einer SwiftUI-Leiste bekommt sie nur Klicks in
/// freie Flächen; Controls über ihr behalten ihre eigene Interaktion.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleView {
        DragHandleView()
    }

    func updateNSView(_ nsView: DragHandleView, context: Context) {}
}

final class DragHandleView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

// MARK: - NativeWindowManager
// Hilfsklasse zum Öffnen von SwiftUI-Views in eigenständigen, echten macOS-Fenstern (NSWindow).

class NativeWindowManager {
    
    // Speichert offene Fenster, damit ARC sie nicht sofort wieder löscht
    static var activeWindows: [NSWindow] = []
    
    /// Öffnet eine beliebige SwiftUI-View in einem neuen, freischwebenden macOS-Fenster.
    /// - Parameters:
    ///   - view: Die SwiftUI-View, die als Fensterinhalt dienen soll.
    ///   - title: Der Titel des Fensters.
    ///   - initialSize: Die Startgröße des Fensters.
    static func openWindow<V: View>(for view: V, title: String, initialSize: CGSize = CGSize(width: 800, height: 600),
                                    fullScreen: Bool = false) {
        let hostingController = NSHostingController(rootView: view)
        
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = title
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        
        // WICHTIG: Das Hauptfenster von LernAssist läuft auf `.floating`. 
        // Unser neues Fenster muss mindestens das gleiche Level haben, 
        // um nicht unsichtbar im Hintergrund zu verschwinden!
        window.level = .popUpMenu
        // Vollbild (grüner Knopf / Doppelklick auf eine Ausgabe): Fenster dieser Ebene dürfen
        // nicht in den Vollbildmodus – beim Wechsel auf normale Ebene, das schwebende Hauptpanel
        // solange ausblenden (es würde sonst über dem Vollbild liegen).
        window.collectionBehavior = [.fullScreenPrimary]
        let fullScreenObservers = FullScreenObservers(window: window)
        
        // ARC: Fenster behalten, solange es offen ist
        activeWindows.append(window)

        // Sobald das Fenster geschlossen wird, aus dem Array entfernen.
        // Audit H6: Der alte Token-lose Observer blockte den NSWindow stark im Closure-Capture
        // und wurde NIE entfernt – jedes jemals geöffnete Fenster (Quiz, Karteikarten,
        // Vollbild-Artefakte inkl. SwiftUI-Inhalt) blieb nach dem Schließen dauerhaft im
        // Speicher. Der Token wird jetzt im Handler selbst entfernt und der Window-Capture
        // ist weak.
        // Token in einer Box, damit der Handler ihn nach dem Zuweisen sicher entfernen kann.
        let box = WindowObserverBox()
        box.token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak window] _ in
            MainActor.assumeIsolated {
                if let window {
                    activeWindows.removeAll { $0 === window }
                }
            }
            if let token = box.token {
                NotificationCenter.default.removeObserver(token)
            }
            fullScreenObservers.remove()
        }
        
        // Zentriere das Fenster auf dem Bildschirm
        window.center()
        
        // Öffne und fokussiere das Fenster (auch wenn die App gerade keinen Fokus hat)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        
        // Um sicherzugehen, dass das Fenster auch über der aktuellen App schwebt und nicht im Hintergrund landet
        NSApp.activate(ignoringOtherApps: true)

        if fullScreen {
            window.level = .normal
            window.toggleFullScreen(nil)
        }
    }

    /// Das schwebende Hauptpanel der App.
    static var mainPanel: NSWindow? {
        NSApp.windows.first { ($0 as? NSPanel)?.isFloatingPanel == true && $0.contentView is NSVisualEffectView }
    }
}


/// Hält den Beobachter-Token, damit der Schließen-Handler ihn nach dem Zuweisen entfernen kann.
private final class WindowObserverBox: @unchecked Sendable {
    var token: NSObjectProtocol?
}

/// Wechselt beim Vollbild die Fensterebene und blendet das schwebende Hauptpanel aus.
private final class FullScreenObservers: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []
    private var panelWasVisible = false

    @MainActor
    init(window: NSWindow) {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                window?.level = .normal
                let panel = NativeWindowManager.mainPanel
                self?.panelWasVisible = panel?.isVisible ?? false
                panel?.orderOut(nil)
            }
        })
        tokens.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                window?.level = .popUpMenu
                if self?.panelWasVisible == true { NativeWindowManager.mainPanel?.orderFront(nil) }
                self?.panelWasVisible = false
            }
        })
        tokens.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.panelWasVisible == true { NativeWindowManager.mainPanel?.orderFront(nil) }
            }
        })
    }

    func remove() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens.removeAll()
    }
}
