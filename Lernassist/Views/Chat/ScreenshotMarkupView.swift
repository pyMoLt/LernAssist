import SwiftUI
import AppKit

// MARK: - ScreenshotMarkupView
// Einfaches Markup-Tool für den Screenshot, der noch unversendet in der InputArea-Vorschau liegt.
// Bewusst NICHT automatisch beim Erfassen geöffnet – der schnelle "Screenshot → Chat" Weg ohne
// Extra-Fenster bleibt unverändert; dieses Tool öffnet sich nur, wenn man aktiv auf die bereits
// abgelegte Vorschau klickt.

struct ScreenshotMarkupView: View {
    let originalImage: NSImage
    let onDone: (NSImage) -> Void
    let onCancel: () -> Void

    private enum MarkupTool: String, CaseIterable {
        case pen, rectangle, arrow, ellipse

        var icon: String {
            switch self {
            case .pen: return "pencil"
            case .rectangle: return "rectangle"
            case .arrow: return "arrow.up.right"
            case .ellipse: return "circle"
            }
        }
        var label: String {
            switch self {
            case .pen: return "Stift"
            case .rectangle: return "Rechteck"
            case .arrow: return "Pfeil"
            case .ellipse: return "Kreis"
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
    @State private var selectedTool: MarkupTool = .pen
    @State private var selectedColor: Color = .red

    private let palette: [Color] = [.red, .yellow, .green, .blue, .white]
    private let lineWidth: CGFloat = 4
    private let canvasSize = CGSize(width: 760, height: 500)

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
            ZStack {
                Color.black.opacity(0.03)
                Image(nsImage: originalImage)
                    .resizable()
                    .frame(width: fitRect.width, height: fitRect.height)
                    .position(x: fitRect.midX, y: fitRect.midY)
                Canvas { context, _ in
                    for stroke in strokes { draw(stroke, into: &context) }
                    if let currentStroke { draw(currentStroke, into: &context) }
                }
                .allowsHitTesting(false)
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .contentShape(Rectangle())
            .gesture(drawGesture)
        }
        .frame(width: canvasSize.width)
    }

    private var header: some View {
        HStack {
            Text("Screenshot markieren")
                .font(.headline)
            Spacer()
            Button("Abbrechen", action: onCancel)
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
        }
        .padding(12)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            ForEach(MarkupTool.allCases, id: \.self) { tool in
                Button {
                    selectedTool = tool
                } label: {
                    Image(systemName: tool.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(selectedTool == tool ? .white : .primary)
                        .padding(8)
                        .background(selectedTool == tool ? Color.accentColor : Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(tool.label)
            }

            Divider().frame(height: 20)

            ForEach(palette, id: \.self) { color in
                Circle()
                    .fill(color)
                    .frame(width: 18, height: 18)
                    .overlay(
                        Circle().stroke(Color.primary.opacity(selectedColor == color ? 0.8 : 0.15),
                                        lineWidth: selectedColor == color ? 2 : 1)
                    )
                    .onTapGesture { selectedColor = color }
            }

            Divider().frame(height: 20)

            Button(action: { strokes.removeLast() }) {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .disabled(strokes.isEmpty)
            .help("Letzte Markierung rückgängig machen")

            Button(action: { strokes.removeAll() }) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .disabled(strokes.isEmpty)
            .help("Alle Markierungen entfernen")

            Spacer()

            Button("Fertig") {
                onDone(flattenedImage())
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Zeichnen

    private var drawGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let p = clamp(value.location)
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
