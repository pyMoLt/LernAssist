import AppKit
import SwiftUI

/// Klick und Doppelklick auf AppKit-Ebene. SwiftUI-Tap-Gesten verpassen im schwebenden, nicht
/// aktivierenden Panel oft den ersten Klick (er macht das Fenster nur aktiv) – ein Doppelklick
/// kam dann als Einzelklick an. Diese Fläche nimmt jeden Klick sofort an (`acceptsFirstMouse`).
/// Ein Einzelklick wartet die Doppelklick-Zeit des Systems ab, damit beide sauber getrennt sind.
struct ClickCatcher: NSViewRepresentable {
    var onSingleClick: (() -> Void)? = nil
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> ClickCatcherView {
        let view = ClickCatcherView()
        view.onSingleClick = onSingleClick
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ view: ClickCatcherView, context: Context) {
        view.onSingleClick = onSingleClick
        view.onDoubleClick = onDoubleClick
    }
}

final class ClickCatcherView: NSView {
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var pendingSingle: DispatchWorkItem?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            pendingSingle?.cancel()
            pendingSingle = nil
            onDoubleClick?()
            return
        }
        guard let onSingleClick else { return }
        let work = DispatchWorkItem { onSingleClick() }
        pendingSingle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    /// Mausrad gehört dem umgebenden Chat.
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

// MARK: - Fenstergröße nach Inhalt

enum ContentWindowSize {
    /// Größe für ein Zusatzfenster: der Inhalt in Originalgröße, höchstens 90 % des Bildschirms.
    @MainActor
    static func fitting(content: CGSize, extraHeight: CGFloat = 0, minimum: CGSize = CGSize(width: 420, height: 300)) -> CGSize {
        let screen = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let maxSize = CGSize(width: screen.width * 0.9, height: screen.height * 0.9)
        return CGSize(width: min(max(content.width, minimum.width), maxSize.width),
                      height: min(max(content.height + extraHeight, minimum.height), maxSize.height))
    }
}
