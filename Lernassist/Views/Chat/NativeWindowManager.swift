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
    static func openWindow<V: View>(for view: V, title: String, initialSize: CGSize = CGSize(width: 800, height: 600)) {
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
        
        // ARC: Fenster behalten, solange es offen ist
        activeWindows.append(window)

        // Sobald das Fenster geschlossen wird, aus dem Array entfernen.
        // Audit H6: Der alte Token-lose Observer blockte den NSWindow stark im Closure-Capture
        // und wurde NIE entfernt – jedes jemals geöffnete Fenster (Quiz, Karteikarten,
        // Vollbild-Artefakte inkl. SwiftUI-Inhalt) blieb nach dem Schließen dauerhaft im
        // Speicher. Der Token wird jetzt im Handler selbst entfernt und der Window-Capture
        // ist weak.
        var closeObserver: NSObjectProtocol?
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak window] _ in
            if let window {
                activeWindows.removeAll { $0 === window }
            }
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
            }
        }
        _ = closeObserver // Token lebt in der Closure (Remove im Handler), hier nur zur Klarheit
        
        // Zentriere das Fenster auf dem Bildschirm
        window.center()
        
        // Öffne und fokussiere das Fenster (auch wenn die App gerade keinen Fokus hat)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        
        // Um sicherzugehen, dass das Fenster auch über der aktuellen App schwebt und nicht im Hintergrund landet
        NSApp.activate(ignoringOtherApps: true)
    }
}
