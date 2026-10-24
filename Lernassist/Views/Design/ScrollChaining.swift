import SwiftUI
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

// MARK: - Dezente Scrollleisten (nur eigene Scroll-Bereiche)

extension NSScrollView {
    /// Schmale, sich ausblendende Scrollleiste – außer der Nutzer hat in den Systemeinstellungen
    /// „Scrollbalken immer anzeigen“ gewählt. Ersetzt das frühere app-weite Swizzling von
    /// `tile()` (Build 14), das jede ScrollView der App inkl. WebKit und Textfeldern traf.
    func applyDiscreetScrollers() {
        guard UserDefaults.standard.string(forKey: "AppleShowScrollBars") != "Always" else { return }
        DiscreetScrollerRegistry.shared.register(self)
        if scrollerStyle != .overlay { scrollerStyle = .overlay }
        if !autohidesScrollers { autohidesScrollers = true }
        if verticalScroller?.controlSize != .small { verticalScroller?.controlSize = .small }
        if horizontalScroller?.controlSize != .small { horizontalScroller?.controlSize = .small }
    }
}

/// Merkt sich die dezent eingestellten Scrollbereiche. macOS stellt den Stil zurück, wenn sich die
/// bevorzugte Darstellung ändert (z. B. Maus angeschlossen, Systemeinstellung geändert) – dann
/// wird er für alle erneut angewendet.
@MainActor
final class DiscreetScrollerRegistry {
    static let shared = DiscreetScrollerRegistry()
    private let views = NSHashTable<NSScrollView>.weakObjects()
    private var observer: NSObjectProtocol?

    func register(_ scrollView: NSScrollView) {
        views.add(scrollView)
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Kurz warten: AppKit setzt den Stil der Scrollbereiche selbst erst nach der Meldung um.
                DispatchQueue.main.async { self?.views.allObjects.forEach { $0.applyDiscreetScrollers() } }
            }
        }
    }
}

/// Als `.background` in eine SwiftUI-ScrollView/List setzen: stellt deren Scrollleiste dezent ein
/// (schmal, nur beim Scrollen sichtbar). SwiftUI legt den Hintergrund nicht immer IN den
/// NSScrollView, daher wird er auch über die Vorfahren gesucht.
struct DiscreetScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? Probe)?.apply()
    }

    final class Probe: NSView {
        private weak var scrollView: NSScrollView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func apply() {
            if scrollView == nil { scrollView = findScrollView() }
            scrollView?.applyDiscreetScrollers()
        }

        /// Der eigene NSScrollView – sonst der kleinste in den Vorfahren, der diese Ansicht abdeckt.
        private func findScrollView() -> NSScrollView? {
            if let enclosing = enclosingScrollView { return enclosing }
            guard let window else { return nil }
            let mine = convert(bounds, to: nil)
            let probe = NSPoint(x: mine.midX, y: mine.midY)
            var ancestor = superview
            while let current = ancestor {
                var best: NSScrollView?
                func search(_ view: NSView) {
                    for sub in view.subviews where !sub.isHidden {
                        if let sv = sub as? NSScrollView, sv.window == window,
                           sv.convert(sv.bounds, to: nil).contains(probe) {
                            if best == nil || sv.frame.width * sv.frame.height < best!.frame.width * best!.frame.height {
                                best = sv
                            }
                        }
                        search(sub)
                    }
                }
                search(current)
                if let best { return best }
                ancestor = current.superview
            }
            return nil
        }
    }
}
