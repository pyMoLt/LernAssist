import SwiftUI
import AppKit

// MARK: - OptimizedImageView
// Nutze ImageStore (Dereferenzierung), um SwiftUI-Diffing-Overhead zu vermeiden.

struct OptimizedImageView: View {
    let imageID: UUID
    let base64: String? // Fallback für Erstladung
    @State private var image: NSImage? = nil

    var body: some View {
        Group {
            if let img = image {
                ZStack(alignment: .topTrailing) {
                    // Höhere Initialhöhe, damit Bilder direkt groß genug für die 300 DPI sind
                    ResizableContainer(initialHeight: 400, minHeight: 200) {
                        InteractiveImageView(image: img, externalZoom: .constant(1.0))
                    }
                    
                    Button {
                        let w = min(max(img.size.width, 800), 1600)
                        let h = min(max(img.size.height, 600), 1200)
                        NativeWindowManager.openWindow(
                            for: NativeImageWindowView(image: img).frame(minWidth: 600, idealWidth: w, maxWidth: .infinity, minHeight: 400, idealHeight: h, maxHeight: .infinity),
                            title: "Bild betrachten",
                            initialSize: CGSize(width: w, height: h)
                        )
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2)
                            .padding(6)
                            .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .help("Vollbild / Größer anzeigen")
                }
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.08))
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

    private func loadImageAsync() async {
        // 1. Cache prüfen (synchron, kein Overhead)
        if let cached = ImageStore.shared.getImage(for: imageID) {
            image = cached
            return
        }
        // 2. Vom Base64 dekodieren (Hintergrund-Thread, nie Main Thread blockieren)
        if let b64 = base64 {
            let decoded = await Task.detached(priority: .userInitiated) {
                Data(base64Encoded: b64).flatMap { NSImage(data: $0) }
            }.value
            if let img = decoded {
                ImageStore.shared.setImage(img, for: imageID)
                image = img
                return
            }
        }
        // 3. Fallback: Bild wurde persistiert, Base64 aber nicht mehr im Message-Objekt
        //    (wiederhergestellter Chat aus einem früheren App-Start) → von Platte laden.
        image = await ImageStore.shared.loadFromDisk(for: imageID)
    }
}

// MARK: - EnlargedImageView

// MARK: - NativeImageWindowView
private struct NativeImageWindowView: View {
    let image: NSImage

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Bild").font(.headline)
                Spacer()
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("In die Zwischenablage kopieren")
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
