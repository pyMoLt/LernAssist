import SwiftUI
import AppKit

// MARK: - ScrollBottomDetector
// Robuste Scroll-Intent-Erkennung mit zwei Notifications (kein KVO):
//
// 1. didLiveScrollNotification  → User scrollt gerade aktiv
//    → Auto-Scroll SOFORT deaktivieren, ohne isAtBottom-Check.
//    (Früherer Bug: isAtBottom-Check während des Scrollens lieferte wegen der
//     80pt-Toleranz in den ersten Events noch true → userScrolledUp blieb false
//     → nächstes Content-Update scrollte den User wieder ans Ende.)
//
// 2. didEndLiveScrollNotification → Scroll-Geste beendet (inkl. Momentum)
//    → Erst JETZT Position prüfen: wenn am Ende, Auto-Scroll reaktivieren.
//    (Sicher, weil keine Intermediate-States mehr, kein KVO-Rauschen.)

final class _ScrollDetectorView: NSView {
    var onScrolled: (() -> Void)?          // feuert bei jedem Live-Scroll-Event
    var onScrollEnded: ((Bool) -> Void)?   // feuert wenn Scroll-Geste endet (atBottom)

    private var liveObserver: Any?
    private var endObserver: Any?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        DispatchQueue.main.async { [weak self] in self?.attachToScrollView() }
    }

    private func attachToScrollView() {
        if let o = liveObserver { NotificationCenter.default.removeObserver(o) }
        if let o = endObserver  { NotificationCenter.default.removeObserver(o) }
        liveObserver = nil
        endObserver  = nil

        var candidate: NSView? = superview
        while let v = candidate {
            if let sv = v as? NSScrollView {

                // Jedes Live-Scroll-Event → sofort Auto-Scroll aus
                liveObserver = NotificationCenter.default.addObserver(
                    forName: NSScrollView.didLiveScrollNotification,
                    object: sv, queue: .main
                ) { [weak self] _ in
                    self?.onScrolled?()
                }

                // Scroll-Geste beendet → Position prüfen → ggf. Auto-Scroll an
                endObserver = NotificationCenter.default.addObserver(
                    forName: NSScrollView.didEndLiveScrollNotification,
                    object: sv, queue: .main
                ) { [weak sv, weak self] _ in
                    guard let sv else { return }
                    let atBottom = Self.isAtBottom(sv: sv)
                    self?.onScrollEnded?(atBottom)
                }

                return
            }
            candidate = v.superview
        }
    }

    private static func isAtBottom(sv: NSScrollView) -> Bool {
        let clip     = sv.contentView
        let contentH = sv.documentView?.frame.height ?? 0
        let visibleH = clip.bounds.height
        let offsetY  = clip.bounds.origin.y
        let maxOff   = max(0, contentH - visibleH)
        return (maxOff - offsetY) < 40   // enger: 40pt reichen nach Ende einer Geste
    }

    deinit {
        if let o = liveObserver { NotificationCenter.default.removeObserver(o) }
        if let o = endObserver  { NotificationCenter.default.removeObserver(o) }
    }
}

struct ScrollBottomDetector: NSViewRepresentable {
    var onScrolled: () -> Void        // User scrollt → Auto-Scroll aus
    var onScrollEnded: (Bool) -> Void // Scroll-Geste endet → ggf. Auto-Scroll an

    func makeNSView(context: Context) -> _ScrollDetectorView {
        let v = _ScrollDetectorView()
        v.onScrolled    = onScrolled
        v.onScrollEnded = onScrollEnded
        return v
    }

    func updateNSView(_ nsView: _ScrollDetectorView, context: Context) {
        nsView.onScrolled    = onScrolled
        nsView.onScrollEnded = onScrollEnded
    }
}
