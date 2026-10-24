import SwiftUI
import AppKit

// MARK: - Design-System 2.0 ("Flowing Surfaces & Tasteful Accents")
//
// Zentrales Fundament für das gesamte UI: Spacing-Skala, harmonische Akzentfarben,
// rahmenlose Soft-Surfaces (vermeiden harte schwarze 1px-Systemränder bei aktivierter
// Kontrasterhöhung) sowie das neue vektorbasierte LernAssist-App-Icon.

enum DS {
    // MARK: Spacing-Skala

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
    }

    // MARK: Radien

    enum Radius {
        static let small: CGFloat = 7
        static let medium: CGFloat = 11
        static let large: CGFloat = 15
        static let extraLarge: CGFloat = 20
        /// Einstellungs-Pillen und schwebende Karten (Version 4).
        static let pill: CGFloat = 18
    }

    // MARK: Kuratierte Akzent-Palette

    enum Accent {
        /// Akzent der Oberfläche – folgt der Einstellung „Akzentfarbe“ (Version 4).
        static var brand: Color { Theme.accentSolid }
        static var indigo: Color { brand }
        /// Verlauf aus Akzent und Begleitfarbe (Symbol-Kacheln, Hervorhebungen).
        static var brandGradient: LinearGradient { Theme.gradient(Theme.current.accent) }

        /// Smaragd / Mint: Live-Token-Speed (Decode), Online-Status, Erfolg.
        static let emerald = Color(red: 0.06, green: 0.72, blue: 0.50)
        /// Bernstein / Amber: Prompt Processing (Prefill), Ladevorgang, Hinweise.
        static let amber = Color(red: 0.95, green: 0.60, blue: 0.05)
        /// Ozeanblau / Cyan: Recherche, Quellen, Diagramme, Wissen.
        static let cyan = Color(red: 0.05, green: 0.58, blue: 0.88)
        /// Kobaltblau: Dokumente, Lernplan, Struktur.
        static let blue = Color(red: 0.23, green: 0.50, blue: 0.96)
        /// Koralle / Rose: Quiz, Stopp-Aktion, Warnungen.
        static let rose = Color(red: 0.94, green: 0.27, blue: 0.44)
    }

    // MARK: Semantische Text- & Linienfarben

    enum Ink {
        /// Primäre Textfarbe (folgt Light/Dark automatisch).
        static let primary = Color.primary
        /// Sekundäre Textfarbe für Labels, Hints, Captions.
        static let secondary = Color.secondary
        /// Subtile Konturlinie (bewusst weich statt hartem System-Separator).
        static let hairline = Color.primary.opacity(0.075)
        /// Akzent für Text, Symbole und Auswahl: im Dark Mode heller, damit er auf dunklen
        /// Flächen lesbar bleibt (das satte Markenviolett war dort kaum zu erkennen).
        static var accent: Color { Theme.accent }
        /// Lern-/Quiz-Assoziation der App.
        static let quiz = Accent.rose
        /// Dokument-/Import-Assoziation.
        static let document = Accent.blue
    }

    // MARK: Organische Flächen ("Flowing Surfaces")

    enum Surface {
        /// Durchgehende Hauptfläche für Header, Chat-Verlauf und unteren Rand (verhindert Streifenbildung).
        static let canvas = Color(nsColor: .windowBackgroundColor)
        /// Sanft abgetönte Seitenleiste ohne harte Trennlinie.
        static let sidebar = Color.primary.opacity(0.032)
        /// Ruhige Karte für Einstellungen, Welcome-Cards und Gruppierungen.
        static let card = Color(nsColor: .controlBackgroundColor).opacity(0.92)
        /// Schwebende Kapsel-/Pill-Fläche (Header-Gruppen, Composer, Telemetrie).
        static let pill = Color(nsColor: .controlBackgroundColor).opacity(0.94)
        /// Rahmenlose Eingabefeld-Fläche in den Einstellungen.
        static let control = Color.primary.opacity(0.048)
        /// Hintergrundfläche für Nachrichten-Chips, Popover-Zeilen etc.
        static let chip = Color.primary.opacity(0.05)
        /// Hover-Variante derselben Fläche.
        static let chipHover = Color.primary.opacity(0.09)
        /// Getönte Nutzer-Bubble (Chat-Nachricht vom Nutzer) mit sanftem Marken-Tint.
        static var bubbleUser: Color { Accent.brand.opacity(0.12) }
        /// Hintergrund der Metrik-/Status-Chips.
        static let status = Color.primary.opacity(0.065)
        /// Subtil abgesetzte Navigation in den Einstellungen.
        static let navigation = Color.primary.opacity(0.032)
        /// Selektionsfarbe für aktive Navigationszeilen.
        static var selection: Color { Accent.brand.opacity(0.16) }
    }
}

// MARK: - LernAssistBrandIcon (Vektor-App-Icon für Header, Sidebar, Welcome & Avatar)

/// Zeichnet das neue LernAssist-App-Icon (Indigo-Violett-Squircle, weiße Sucher-Ecken,
/// Milchglas-Kachel, weißer Doktorhut mit goldener Quaste) gestochen scharf in jeder Größe.
struct LernAssistBrandIcon: View {
    var size: CGFloat = 32
    var isCircle: Bool = false

    var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let s = min(w, h)
            let scale = s / 1024.0

            // 1. Hintergrund-Verlauf (#8E5BF0 → #6A3FD6 → #3B2A9E)
            let bgRect = CGRect(x: 0, y: 0, width: w, height: h)
            context.fill(
                Path(bgRect),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: Color(red: 0.557, green: 0.357, blue: 0.941), location: 0.0),
                        .init(color: Color(red: 0.416, green: 0.247, blue: 0.839), location: 0.55),
                        .init(color: Color(red: 0.231, green: 0.165, blue: 0.620), location: 1.0)
                    ]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: w, y: h)
                )
            )

            // Radialer Lichtglanz oben links
            context.fill(
                Path(bgRect),
                with: .radialGradient(
                    Gradient(colors: [Color.white.opacity(0.32), Color.white.opacity(0.0)]),
                    center: CGPoint(x: w * 0.28, y: h * 0.20),
                    startRadius: 0,
                    endRadius: s * 0.60
                )
            )

            // 2. Weiße Sucher-Ecken (Viewfinder)
            var vf = Path()
            // Oben links
            vf.move(to: CGPoint(x: 232 * scale, y: 372 * scale))
            vf.addLine(to: CGPoint(x: 232 * scale, y: 292 * scale))
            vf.addQuadCurve(to: CGPoint(x: 292 * scale, y: 232 * scale), control: CGPoint(x: 232 * scale, y: 232 * scale))
            vf.addLine(to: CGPoint(x: 372 * scale, y: 232 * scale))
            // Oben rechts
            vf.move(to: CGPoint(x: 652 * scale, y: 232 * scale))
            vf.addLine(to: CGPoint(x: 732 * scale, y: 232 * scale))
            vf.addQuadCurve(to: CGPoint(x: 792 * scale, y: 292 * scale), control: CGPoint(x: 792 * scale, y: 232 * scale))
            vf.addLine(to: CGPoint(x: 792 * scale, y: 372 * scale))
            // Unten rechts
            vf.move(to: CGPoint(x: 792 * scale, y: 652 * scale))
            vf.addLine(to: CGPoint(x: 792 * scale, y: 732 * scale))
            vf.addQuadCurve(to: CGPoint(x: 732 * scale, y: 792 * scale), control: CGPoint(x: 792 * scale, y: 792 * scale))
            vf.addLine(to: CGPoint(x: 652 * scale, y: 792 * scale))
            // Unten links
            vf.move(to: CGPoint(x: 372 * scale, y: 792 * scale))
            vf.addLine(to: CGPoint(x: 292 * scale, y: 792 * scale))
            vf.addQuadCurve(to: CGPoint(x: 232 * scale, y: 732 * scale), control: CGPoint(x: 232 * scale, y: 792 * scale))
            vf.addLine(to: CGPoint(x: 232 * scale, y: 652 * scale))

            context.stroke(
                vf,
                with: .color(.white.opacity(0.95)),
                style: StrokeStyle(lineWidth: max(1.4, 44 * scale), lineCap: .round, lineJoin: .round)
            )

            // 3. Innere Glas-Kachel
            let glassRect = CGRect(x: 322 * scale, y: 322 * scale, width: 380 * scale, height: 380 * scale)
            let glassPath = Path(roundedRect: glassRect, cornerRadius: 92 * scale, style: .continuous)
            context.fill(
                glassPath,
                with: .linearGradient(
                    Gradient(colors: [Color.white.opacity(0.50), Color.white.opacity(0.20)]),
                    startPoint: CGPoint(x: 512 * scale, y: 322 * scale),
                    endPoint: CGPoint(x: 512 * scale, y: 702 * scale)
                )
            )
            context.stroke(glassPath, with: .color(.white.opacity(0.68)), lineWidth: max(0.8, 6 * scale))

            // 4. Doktorhut (Dach + Kappe + goldene Quaste)
            var capTop = Path()
            capTop.move(to: CGPoint(x: 512 * scale, y: 410 * scale))
            capTop.addLine(to: CGPoint(x: 652 * scale, y: 470 * scale))
            capTop.addLine(to: CGPoint(x: 512 * scale, y: 530 * scale))
            capTop.addLine(to: CGPoint(x: 372 * scale, y: 470 * scale))
            capTop.closeSubpath()
            context.fill(capTop, with: .color(.white))

            var capBase = Path()
            capBase.move(to: CGPoint(x: 432 * scale, y: 500 * scale))
            capBase.addLine(to: CGPoint(x: 432 * scale, y: 560 * scale))
            capBase.addQuadCurve(
                to: CGPoint(x: 592 * scale, y: 560 * scale),
                control: CGPoint(x: 512 * scale, y: 610 * scale)
            )
            capBase.addLine(to: CGPoint(x: 592 * scale, y: 500 * scale))
            capBase.addLine(to: CGPoint(x: 512 * scale, y: 534 * scale))
            capBase.closeSubpath()
            context.fill(capBase, with: .color(.white.opacity(0.92)))

            var tassel = Path()
            tassel.move(to: CGPoint(x: 640 * scale, y: 476 * scale))
            tassel.addLine(to: CGPoint(x: 640 * scale, y: 560 * scale))
            let gold = Color(red: 1.0, green: 0.824, blue: 0.290)
            context.stroke(tassel, with: .color(gold), style: StrokeStyle(lineWidth: max(1.2, 14 * scale), lineCap: .round))

            let dotRadius = max(1.4, 18 * scale)
            let dotRect = CGRect(x: 640 * scale - dotRadius, y: 572 * scale - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
            context.fill(Path(ellipseIn: dotRect), with: .color(gold))
        }
        .frame(width: size, height: size)
        .clipShape(
            isCircle
                ? AnyShape(Circle())
                : AnyShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        )
        .overlay(
            Group {
                if isCircle {
                    Circle().stroke(Color.white.opacity(0.22), lineWidth: 0.75)
                } else {
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 0.75)
                }
            }
        )
        .shadow(color: DS.Accent.brand.opacity(0.22), radius: max(2, size * 0.14), x: 0, y: max(1, size * 0.06))
    }
}

// MARK: - Surface-Bausteine

/// Einheitliche Karte für ruhige, informationsreiche Bereiche – ohne harte schwarze Konturlinien.
struct AppCard<Content: View>: View {
    private let content: Content
    var padding: CGFloat = DS.Space.l

    init(padding: CGFloat = DS.Space.l, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        // Version 4: Karte im Pillen-Stil – Glas, Milchglas oder deckend je nach Darstellung.
        content
            .padding(.horizontal, padding + 2)
            .padding(.vertical, padding - 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: DS.Radius.pill)
    }
}

// MARK: - Soft-Glass-Chips & Buttons (ohne schwarze High-Contrast-Ränder)

/// Organischer Steuerungs-Chip für Header-Elemente, Status-Kapseln und Popover-Trigger.
/// Vermeidet `.glassEffect`, damit macOS bei aktivierter Kontrasterhöhung keinen schwarzen 1px-Rahmen erzwingt.
struct GlassChip<Content: View>: View {
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isHovered = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(Capsule().fill(isHovered ? DS.Surface.chipHover : .clear))
            .glassSurface(Capsule())
            .opacity(controlActiveState == .inactive ? 0.75 : 1.0)
            .onHover { isHovered = $0 }
    }
}

/// Icon-Button mit sanfter Kapsel-/Kreisfläche und Hover-Feedback (ohne harten schwarzen Systemrand).
struct GlassIconButton: View {
    let systemImage: String
    let help: String
    var tint: Color? = nil
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint ?? (isHovered ? DS.Ink.accent : .primary))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(isHovered ? DS.Accent.brand.opacity(0.10) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { isHovered = $0 }
    }
}

/// Teilen-Button im Safari-Stil, passend zur organischen Header-Gruppe.
struct GlassShareButton: View {
    let provideItem: () -> String
    let help: String
    @State private var isHovered = false

    var body: some View {
        Button {
            Self.showSharePicker(for: provideItem())
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHovered ? DS.Ink.accent : .primary)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(isHovered ? DS.Accent.brand.opacity(0.10) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { isHovered = $0 }
    }

    /// Öffnet den System-Share-Picker (wie Safari): Mail, Notizen, AirDrop usw.
    static func showSharePicker(for text: String) {
        guard !text.isEmpty,
              let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }),
              let contentView = panel.contentView else { return }
        let picker = NSSharingServicePicker(items: [text])
        let rect = NSRect(x: contentView.bounds.width - 240, y: 48, width: 12, height: 12)
        picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
    }
}
