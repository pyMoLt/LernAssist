import SwiftUI
import AppKit

// MARK: - ScreenshotMarkupView
// Einfaches Markup-Tool für den Screenshot, der noch unversendet in der InputArea-Vorschau liegt.
// Bewusst NICHT automatisch beim Erfassen geöffnet – der schnelle "Screenshot → Chat" Weg ohne
// Extra-Fenster bleibt unverändert; dieses Tool öffnet sich nur, wenn man aktiv auf die bereits
// abgelegte Vorschau klickt.

struct ScreenshotMarkupView: View {
    let originalImage: NSImage
    /// Fertiges Bild und ob nur ein Ausschnitt gewählt wurde.
    let onDone: (NSImage, Bool) -> Void
    let onCancel: () -> Void

    private enum MarkupTool: String, CaseIterable {
        case crop, pen, rectangle, arrow, ellipse

        var icon: String {
            switch self {
            case .crop: return "crop"
            case .pen: return "pencil"
            case .rectangle: return "rectangle"
            case .arrow: return "arrow.up.right"
            case .ellipse: return "circle"
            }
        }
        var label: String {
            switch self {
            case .crop: return L("Ausschnitt wählen (nur dieser Bereich wird gesendet)")
            case .pen: return L("Stift")
            case .rectangle: return L("Rechteck")
            case .arrow: return L("Pfeil")
            case .ellipse: return L("Kreis")
            }
        }
    }

    private struct Stroke {
        var tool: MarkupTool
        var points: [CGPoint]   // Stift: alle Punkte. Formen: [Start, aktueller Endpunkt].
        var color: Color
        var lineWidth: CGFloat
    }

    @State private var strokes: [Stroke] = []
    @State private var currentStroke: Stroke?
    @State private var selectedTool: MarkupTool = .crop
    /// Gewählter Ausschnitt in Canvas-Koordinaten (nil = ganzes Bild).
    @State private var cropRect: CGRect?
    @State private var cropStart: CGPoint?
    @State private var selectedColor: Color = .red

    private let palette: [Color] = [.red, .yellow, .green, .blue, .white]
    private let lineWidth: CGFloat = 4
    /// Wird per GeometryReader an die tatsächliche Fenstergröße angepasst (Start: 760×500).
    @State private var canvasSize = CGSize(width: 760, height: 500)

    /// Fit-Rect des Originalbildes innerhalb des Canvas (Letterboxing bei abweichendem
    /// Seitenverhältnis berücksichtigt) – Zeichenkoordinaten werden darauf begrenzt.
    private var fitRect: CGRect {
        let imgSize = originalImage.size
        guard imgSize.width > 0, imgSize.height > 0 else { return CGRect(origin: .zero, size: canvasSize) }
        let scale = min(canvasSize.width / imgSize.width, canvasSize.height / imgSize.height)
        let displaySize = CGSize(width: imgSize.width * scale, height: imgSize.height * scale)
        let origin = CGPoint(x: (canvasSize.width - displaySize.width) / 2, y: (canvasSize.height - displaySize.height) / 2)
        return CGRect(origin: origin, size: displaySize)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            toolbar
            Divider()
            GeometryReader { geo in
                ZStack {
                    Color.black.opacity(0.03)
                    Image(nsImage: originalImage)
                        .resizable()
                        .frame(width: fitRect.width, height: fitRect.height)
                        .position(x: fitRect.midX, y: fitRect.midY)
                    Canvas { context, _ in
                        for stroke in strokes { draw(stroke, into: &context) }
                        if let currentStroke { draw(currentStroke, into: &context) }
                        if let cropRect {
                            // Außerhalb des Ausschnitts abdunkeln, Rand gestrichelt.
                            var outside = Path(fitRect)
                            outside.addRect(cropRect)
                            context.fill(outside, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
                            context.stroke(Path(cropRect), with: .color(.white),
                                           style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        }
                    }
                    .allowsHitTesting(false)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(drawGesture)
                .onAppear { updateCanvas(geo.size) }
                .onChange(of: geo.size) { _, new in updateCanvas(new) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 440, idealWidth: 700, minHeight: 360, idealHeight: 560)
    }

    /// Passt die Leinwand an die verfügbare Größe an. Bereits gezeichnete Striche und der
    /// Ausschnitt werden nur zurückgesetzt, wenn sich die Größe tatsächlich ändert.
    private func updateCanvas(_ size: CGSize) {
        guard size.width > 100, size.height > 100,
              abs(size.width - canvasSize.width) > 1 || abs(size.height - canvasSize.height) > 1 else { return }
        let sx = size.width / canvasSize.width, sy = size.height / canvasSize.height
        func map(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * sx, y: p.y * sy) }
        strokes = strokes.map { var st = $0; st.points = st.points.map(map); return st }
        if let r = cropRect { cropRect = CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy) }
        canvasSize = size
    }

    private var header: some View {
        HStack {
            Text(L("Screenshot markieren"))
                .font(.headline)
            Spacer()
            Button(L("Abbrechen"), action: onCancel)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            ForEach(MarkupTool.allCases, id: \.self) { tool in
                Button {
                    selectedTool = tool
                } label: {
                    Image(systemName: tool.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(selectedTool == tool ? .white : .primary)
                        .padding(6)
                        .background(selectedTool == tool ? Color.accentColor : Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(tool.label)
            }

            Divider().frame(height: 18)

            HStack(spacing: 6) {
                ForEach(palette, id: \.self) { color in
                    Circle()
                        .fill(color)
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle().stroke(Color.primary.opacity(selectedColor == color ? 0.8 : 0.15),
                                            lineWidth: selectedColor == color ? 2 : 1)
                        )
                        .onTapGesture { selectedColor = color }
                }
            }

            Divider().frame(height: 18)

            Button(action: { strokes.removeLast() }) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .medium))
                    .padding(5)
            }
            .buttonStyle(.plain)
            .disabled(strokes.isEmpty)
            .help(L("Letzte Markierung rückgängig machen"))

            Button(action: { strokes.removeAll(); cropRect = nil }) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .padding(5)
            }
            .buttonStyle(.plain)
            .disabled(strokes.isEmpty && cropRect == nil)
            .help(L("Alle Markierungen entfernen"))

            Spacer(minLength: 8)

            Button(cropRect == nil ? L("Fertig") : L("Ausschnitt übernehmen")) {
                onDone(finalImage(), cropRect != nil)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Zeichnen

    private var drawGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let p = clamp(value.location)
                if selectedTool == .crop {
                    let start = cropStart ?? clamp(value.startLocation)
                    cropStart = start
                    cropRect = CGRect(origin: start, size: .zero).union(CGRect(origin: p, size: .zero))
                    return
                }
                if currentStroke == nil {
                    currentStroke = Stroke(tool: selectedTool, points: [p], color: selectedColor, lineWidth: lineWidth)
                } else if selectedTool == .pen {
                    currentStroke?.points.append(p)
                } else if currentStroke!.points.count > 1 {
                    currentStroke!.points[1] = p
                } else {
                    currentStroke!.points.append(p)
                }
            }
            .onEnded { _ in
                if selectedTool == .crop {
                    cropStart = nil
                    if let rect = cropRect, rect.width < 12 || rect.height < 12 { cropRect = nil }
                    return
                }
                if let currentStroke, !currentStroke.points.isEmpty {
                    strokes.append(currentStroke)
                }
                currentStroke = nil
            }
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, fitRect.minX), fitRect.maxX),
                y: min(max(p.y, fitRect.minY), fitRect.maxY))
    }

    private func draw(_ stroke: Stroke, into context: inout GraphicsContext) {
        guard !stroke.points.isEmpty else { return }
        let style = StrokeStyle(lineWidth: stroke.lineWidth, lineCap: .round, lineJoin: .round)
        var path = Path()

        switch stroke.tool {
        case .crop:
            return
        case .pen:
            path.move(to: stroke.points[0])
            for pt in stroke.points.dropFirst() { path.addLine(to: pt) }
            context.stroke(path, with: .color(stroke.color), style: style)

        case .rectangle:
            guard stroke.points.count >= 2 else { return }
            let rect = CGRect(origin: stroke.points[0], size: .zero).union(CGRect(origin: stroke.points[1], size: .zero))
            path.addRect(rect)
            context.stroke(path, with: .color(stroke.color), style: style)

        case .ellipse:
            guard stroke.points.count >= 2 else { return }
            let rect = CGRect(origin: stroke.points[0], size: .zero).union(CGRect(origin: stroke.points[1], size: .zero))
            path.addEllipse(in: rect)
            context.stroke(path, with: .color(stroke.color), style: style)

        case .arrow:
            guard stroke.points.count >= 2 else { return }
            let start = stroke.points[0]
            let end = stroke.points[1]
            path.move(to: start)
            path.addLine(to: end)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let arrowLength: CGFloat = 14
            let arrowAngle: CGFloat = .pi / 7
            let p1 = CGPoint(x: end.x - arrowLength * cos(angle - arrowAngle), y: end.y - arrowLength * sin(angle - arrowAngle))
            let p2 = CGPoint(x: end.x - arrowLength * cos(angle + arrowAngle), y: end.y - arrowLength * sin(angle + arrowAngle))
            path.move(to: end); path.addLine(to: p1)
            path.move(to: end); path.addLine(to: p2)
            context.stroke(path, with: .color(stroke.color), style: style)
        }
    }

    /// Bild mit Markierungen, ggf. auf den gewählten Ausschnitt zugeschnitten (in Pixeln).
    private func finalImage() -> NSImage {
        let full = flattenedImage()
        guard let cropRect, fitRect.width > 0,
              let cg = full.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return full }
        let pxPerPoint = CGFloat(cg.width) / fitRect.width
        let pixelRect = CGRect(x: (cropRect.minX - fitRect.minX) * pxPerPoint,
                               y: (cropRect.minY - fitRect.minY) * pxPerPoint,
                               width: cropRect.width * pxPerPoint,
                               height: cropRect.height * pxPerPoint).integral
        guard let cropped = cg.cropping(to: pixelRect) else { return full }
        let pointSize = NSSize(width: cropRect.width * full.size.width / fitRect.width,
                               height: cropRect.height * full.size.height / fitRect.height)
        return NSImage(cgImage: cropped, size: pointSize)
    }

    /// Rendert Bild + Markierungen zusammen in der ORIGINAL-Pixelauflösung (nicht der kleineren
    /// Canvas-Anzeigegröße), damit der gesendete Screenshot keine Qualität verliert.
    private func flattenedImage() -> NSImage {
        guard !strokes.isEmpty else { return originalImage }
        let scale = originalImage.size.width / max(fitRect.width, 1)

        func scaledStroke(_ s: Stroke) -> Stroke {
            var copy = s
            copy.points = s.points.map { CGPoint(x: ($0.x - fitRect.minX) * scale, y: ($0.y - fitRect.minY) * scale) }
            copy.lineWidth = s.lineWidth * scale
            return copy
        }
        let scaledStrokes = strokes.map(scaledStroke)

        let renderer = ImageRenderer(content:
            ZStack {
                Image(nsImage: originalImage)
                Canvas { context, _ in
                    for s in scaledStrokes { draw(s, into: &context) }
                }
            }
            .frame(width: originalImage.size.width, height: originalImage.size.height)
        )
        // Backing-Skalierung des Originalbilds ermitteln (Retina-Screenshots haben oft eine
        // NSImage.size in "Punkten", die kleiner ist als die tatsächliche Pixelauflösung) –
        // ohne das würde das markierte Bild in halber Auflösung herauskommen.
        if let rep = originalImage.representations.first, originalImage.size.width > 0 {
            let factor = (CGFloat(rep.pixelsWide) / originalImage.size.width).rounded()
            renderer.scale = max(1.0, factor)
        }
        return renderer.nsImage ?? originalImage
    }
}
