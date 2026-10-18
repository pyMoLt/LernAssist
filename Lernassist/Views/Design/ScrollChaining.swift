import AppKit

/// Scroll-Verkettung für verschachtelte Scrollbereiche (Code-Editor, Terminal, Tool-Ausgaben im
/// Chat): Ist der innere Bereich in Scrollrichtung am Ende – oder passt sein Inhalt ganz hinein –,
/// scrollt die Geste den umgebenden Chat weiter, statt „hängen zu bleiben“. Wie im Web üblich wird
/// das Ziel einmal pro Geste (inkl. Nachlauf) festgelegt, damit nichts mitten in der Bewegung springt.
@MainActor
final class ScrollChaining {
    static let shared = ScrollChaining()

    private var monitor: Any?
    /// Ziel der laufenden Geste: der äußere Scrollbereich oder nil (= normal zustellen).
    private weak var gestureTarget: NSScrollView?
    private var gestureForwarded = false
    /// Mausräder liefern keine Gesten-Phasen: Ereignisse in kurzer Folge gelten als eine Geste,
    /// damit der teure Treffertest durch die ganze Ansicht nicht bei jeder Raste läuft.
    private var lastWheelEvent: TimeInterval = 0
    private static let wheelGestureGap: TimeInterval = 0.3

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.route(event)
        }
    }

    private func route(_ event: NSEvent) -> NSEvent? {
        // Neue Geste (Trackpad: .began; Maus: keine Phasen) → Ziel neu bestimmen.
        let isWheel = event.phase == [] && event.momentumPhase == []
        let wheelContinues = isWheel && event.timestamp - lastWheelEvent < Self.wheelGestureGap
        if isWheel { lastWheelEvent = event.timestamp }
        let startsGesture = event.phase == .began || event.phase == .mayBegin || (isWheel && !wheelContinues)
        if startsGesture {
            gestureForwarded = false
            gestureTarget = nil
            lastInner = nil
            lastOuter = nil
            if let (inner, outer) = scrollViews(for: event) {
                lastOuter = outer
                if !Self.canScroll(inner, deltaY: event.scrollingDeltaY, deltaX: event.scrollingDeltaX) {
                    gestureTarget = outer
                    gestureForwarded = true
                }
            }
        } else if wheelContinues, !gestureForwarded, let inner = lastInner, let outer = lastOuter,
                  !Self.canScroll(inner, deltaY: event.scrollingDeltaY, deltaX: event.scrollingDeltaX) {
            // Mausrad im inneren Bereich am Ende angekommen: ohne neuen Treffertest weiter an den Chat.
            gestureTarget = outer
            gestureForwarded = true
        }
        guard gestureForwarded, let outer = gestureTarget else { return event }
        // Inneren Bereich wieder freigeben, sobald er in Gegenrichtung scrollen kann.
        if isWheel, let (inner, _) = cachedInner(for: event),
           Self.canScroll(inner, deltaY: event.scrollingDeltaY, deltaX: event.scrollingDeltaX) {
            gestureForwarded = false
            gestureTarget = nil
            return event
        }
        outer.scrollWheel(with: event)
        if event.momentumPhase == .ended || event.phase == .cancelled {
            gestureForwarded = false
            gestureTarget = nil
        }
        return nil
    }

    private weak var lastInner: NSScrollView?
    private weak var lastOuter: NSScrollView?

    /// Beim Mausrad: der zuletzt bestimmte innere Bereich (ohne neuen Treffertest).
    private func cachedInner(for event: NSEvent) -> (NSScrollView, NSScrollView)? {
        guard let inner = lastInner, let outer = gestureTarget else { return nil }
        return (inner, outer)
    }

    /// Innerer und äußerer NSScrollView unter dem Mauszeiger (nur bei echter Verschachtelung).
    private func scrollViews(for event: NSEvent) -> (NSScrollView, NSScrollView)? {
        guard let window = event.window, let content = window.contentView,
              let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)),
              let inner = hit.enclosingScrollView,
              let outer = inner.superview?.enclosingScrollView else { return nil }
        lastInner = inner
        return (inner, outer)
    }

    /// Kann `scrollView` in Richtung der Geste noch scrollen?
    static func canScroll(_ scrollView: NSScrollView, deltaY: CGFloat, deltaX: CGFloat) -> Bool {
        guard let document = scrollView.documentView else { return false }
        let visible = scrollView.contentView.bounds
        let content = document.frame
        // Überwiegend horizontale Geste: der innere Bereich darf seitlich scrollen (langer Code).
        if abs(deltaX) > abs(deltaY) {
            return content.width > visible.width + 1
        }
        guard content.height > visible.height + 1, deltaY != 0 else { return false }
        // deltaY > 0 = Richtung Anfang (nach oben).
        let towardsTop = deltaY > 0
        let atTop: Bool
        let atBottom: Bool
        if document.isFlipped {
            atTop = visible.minY <= content.minY + 1
            atBottom = visible.maxY >= content.maxY - 1
        } else {
            atTop = visible.maxY >= content.maxY - 1
            atBottom = visible.minY <= content.minY + 1
        }
        return towardsTop ? !atTop : !atBottom
    }
}
