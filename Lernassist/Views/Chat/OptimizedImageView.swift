import SwiftUI
import AppKit

// MARK: - OptimizedImageView
// Nutze ImageStore (Dereferenzierung), um SwiftUI-Diffing-Overhead zu vermeiden.

struct OptimizedImageView: View {
    let imageID: UUID
    let base64: String? // Fallback für Erstladung
    @State private var image: NSImage? = nil
    @State private var loadFailed: Bool = false

    var body: some View {
        Group {
            if let img = image {
                ZStack(alignment: .topTrailing) {
                    // Seitenrichtig ohne Leerraum (vorher fester 400-pt-Container → Streifen über
                    // breiten Plots). Zoomen/Verschieben bietet das Vollbild-Fenster.
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(img.size.width > 0 && img.size.height > 0 ? img.size.width / img.size.height : 1.5, contentMode: .fit)
                        .frame(maxHeight: 560)
                        // Doppelklick öffnet das Bild im eigenen Fenster (AppKit-Klick, siehe ClickCatcher).
                        .overlay(ClickCatcher(onDoubleClick: { openLarge() }))
                    
                    Button {
                        openLarge()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2)
                            .padding(6)
                            .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .help(L("Vollbild / Größer anzeigen"))
                }
            } else if loadFailed {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Bild nicht mehr lokal verfügbar"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(L("Archivierter Anhang"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.Space.s)
                .background(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous).fill(DS.Surface.control))
            } else {
                RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                    .fill(DS.Surface.control)
                    .frame(width: 200, height: 120)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        // .task(id:) statt .onAppear: wird automatisch gecancelt wenn View verschwindet
        // (LazyVStack unmountet Zellen beim Scrollen) und neu gestartet wenn sie wieder
        // erscheint. Verhindert parallele Dekodierungs-Tasks beim Rein-/Rausscrollen.
        .task(id: imageID) {
            await loadImageAsync()
        }
    }

    /// Vollbild mit dem Original (die Chat-Ansicht zeigt nur eine verkleinerte Fassung).
    private func openLarge() {
        Task {
            var full = ImageStore.shared.getImage(for: imageID)
            if full == nil, let b64 = base64 {
                full = await Task.detached(priority: .userInitiated) {
                    Data(base64Encoded: b64).flatMap { NSImage(data: $0) }
                }.value
            }
            if full == nil { full = await ImageStore.shared.loadFromDisk(for: imageID) }
            if let full { openLarge(full) }
        }
    }

    private func openLarge(_ img: NSImage) { Self.openImageWindow(img) }

    /// Bild groß im eigenen Fenster (auch für Abbildungen aus der Recherche).
    static func openImageWindow(_ img: NSImage) {
        // Fenster in Bildgröße (höchstens 90 % des Bildschirms); beim Verkleinern passt sich das
        // Bild an, solange man nicht selbst zoomt.
        let size = ContentWindowSize.fitting(content: img.size, extraHeight: 44)
        NativeWindowManager.openWindow(
            for: NativeImageWindowView(image: img).frame(minWidth: 300, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity),
            title: L("Bild betrachten"),
            initialSize: size
        )
    }

    /// Verkleinerte Fassungen für den Chat (Schlüssel: Bild-ID).
    private static let displayCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 60
        return cache
    }()

    /// Längste Seite der Chat-Fassung in Pixeln. Screenshots haben oft 3000 px und mehr – sie bei
    /// jedem Bild in voller Auflösung zu skalieren, ließ das Scrollen über Bildern ruckeln.
    nonisolated static let displayMaxPixels: CGFloat = 1_600

    /// Verkleinert ein Bild (Hintergrund-Thread) – Seitenverhältnis und Punktgröße bleiben gleich.
    nonisolated static func displayVersion(of image: NSImage, maxPixels: CGFloat = displayMaxPixels) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let longest = CGFloat(max(cg.width, cg.height))
        guard longest > maxPixels else { return image }
        let scale = maxPixels / longest
        let width = Int(CGFloat(cg.width) * scale), height = Int(CGFloat(cg.height) * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return image }
        return NSImage(cgImage: small, size: image.size)
    }

    private func loadImageAsync() async {
        loadFailed = false
        if let shown = Self.displayCache.object(forKey: imageID.uuidString as NSString) {
            image = shown
            return
        }
        guard let full = await loadFullImage() else {
            loadFailed = true
            return
        }
        let shown = await Task.detached(priority: .userInitiated) { Self.displayVersion(of: full) }.value
        Self.displayCache.setObject(shown, forKey: imageID.uuidString as NSString)
        image = shown
    }

    private func loadFullImage() async -> NSImage? {
        // 1. Cache prüfen (synchron, kein Overhead)
        if let cached = ImageStore.shared.getImage(for: imageID) {
            return cached
        }
        // 2. Vom Base64 dekodieren (Hintergrund-Thread, nie Main Thread blockieren)
        if let b64 = base64 {
            let decoded = await Task.detached(priority: .userInitiated) {
                Data(base64Encoded: b64).flatMap { NSImage(data: $0) }
            }.value
            if let img = decoded {
                ImageStore.shared.setImage(img, for: imageID)
                return img
            }
        }
        // 3. Fallback: Bild wurde persistiert, Base64 aber nicht mehr im Message-Objekt
        //    (wiederhergestellter Chat aus einem früheren App-Start) → von Platte laden.
        return await ImageStore.shared.loadFromDisk(for: imageID)
    }
}

// MARK: - EnlargedImageView

// MARK: - NativeImageWindowView
private struct NativeImageWindowView: View {
    let image: NSImage

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Bild")).font(.headline)
                Spacer()
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help(L("In die Zwischenablage kopieren"))
            }
            .padding(10)
            Divider()
            NativeZoomImageView(image: image)
        }
    }
}

// MARK: - InteractiveImageView
// Kapselt ein Image mit stufenlosem Zoom (Pinch) und Pan (Drag).
struct InteractiveImageView: View {
    let image: NSImage
    @Binding var externalZoom: CGFloat
    
    @State private var currentScale: CGFloat = 1.0
    @State private var finalScale: CGFloat = 1.0
    
    @State private var currentOffset: CGSize = .zero
    @State private var finalOffset: CGSize = .zero
    
    var body: some View {
        GeometryReader { proxy in
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(finalScale * currentScale * externalZoom)
                .offset(x: finalOffset.width + currentOffset.width, y: finalOffset.height + currentOffset.height)
                .gesture(
                    MagnificationGesture()
                        .onChanged { val in
                            currentScale = val
                        }
                        .onEnded { val in
                            finalScale *= currentScale
                            currentScale = 1.0
                            if finalScale < 1.0 {
                                withAnimation(.spring()) {
                                    finalScale = 1.0
                                    finalOffset = .zero
                                }
                            }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { val in
                            // Pan nur erlauben, wenn herangezoomt ist
                            if (finalScale * currentScale) > 1.0 {
                                currentOffset = val.translation
                            }
                        }
                        .onEnded { val in
                            if (finalScale * currentScale) > 1.0 {
                                finalOffset.width += currentOffset.width
                                finalOffset.height += currentOffset.height
                                currentOffset = .zero
                            }
                        }
                )
        }
        .clipped()
        .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
    }
}
