import SwiftUI
import AppKit

// MARK: - NativeZoomImageView
// Wraps an NSScrollView with NSImageView to provide 100% native macOS zooming (Pinch & Option+Scroll) and panning.

struct NativeZoomImageView: NSViewRepresentable {
    let image: NSImage
    
    func makeNSView(context: Context) -> MouseWheelZoomScrollView {
        let scrollView = MouseWheelZoomScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 10.0
        
        // Transparent background
        scrollView.drawsBackground = false
        
        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = CGRect(origin: .zero, size: image.size)
        
        scrollView.documentView = imageView
        
        // Initial zoom to fit – mit Retry statt einmaligem main.async-Hop (Audit U12): Die
        // Bounds des ScrollViews sind im ersten main.async oft noch 0, das Fit-to-Window lief
        // dann ins Leere und das Bild erschien in Originalgröße. Kurz pollen, bis das Layout
        // steht (max. ~30 Frames ≈ 0,5 s), dann einpassen und zentrieren.
        DispatchQueue.main.async {
            func attemptFit(_ attempt: Int) {
                guard scrollView.bounds.width > 0 else {
                    if attempt < 30 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { attemptFit(attempt + 1) }
                    }
                    return
                }
                if let docView = scrollView.documentView {
                    let aspectWidth = scrollView.bounds.width / image.size.width
                    let aspectHeight = scrollView.bounds.height / image.size.height
                    let minAspect = min(aspectWidth, aspectHeight)
                    if minAspect < 1.0 {
                        scrollView.magnification = minAspect
                    }
                    let x = (docView.frame.width - scrollView.bounds.width) / 2
                    let y = (docView.frame.height - scrollView.bounds.height) / 2
                    scrollView.contentView.bounds.origin = CGPoint(x: max(0, x), y: max(0, y))
                }
            }
            attemptFit(0)
        }
        
        return scrollView
    }
    
    func updateNSView(_ nsView: MouseWheelZoomScrollView, context: Context) {
        if let imageView = nsView.documentView as? NSImageView, imageView.image != image {
            imageView.image = image
            imageView.frame = CGRect(origin: .zero, size: image.size)
        }
    }
}

class MouseWheelZoomScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        // Zoom NUR mit explizitem Modifier (Option/Command/Control); Mausrad und Trackpad
        // scrollen standardmäßig (Audit U12: Vorher zoomte JEDES Mausrad-Ereignis und Pannen
        // war nur mit Shift möglich – genau invertiert zur nativen macOS-Konvention, unter der
        // Scrollen scrollt und Option+Scroll zoomt).
        let hasZoomModifier = event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)

        if hasZoomModifier {
            let delta = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY * 0.01
                : (event.scrollingDeltaY > 0 ? 0.15 : -0.15)
            let newMagnification = self.magnification * (1.0 + delta)
            let clampedMagnification = max(self.minMagnification, min(self.maxMagnification, newMagnification))

            let locationInWindow = event.locationInWindow
            let locationInView = self.contentView.convert(locationInWindow, from: nil)

            self.setMagnification(clampedMagnification, centeredAt: locationInView)
            return
        }

        super.scrollWheel(with: event)
    }
}
