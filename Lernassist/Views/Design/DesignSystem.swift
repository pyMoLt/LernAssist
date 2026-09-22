import SwiftUI

// MARK: - Design-System (Phase G)
//
// Zentrales Fundament für das gesamte UI: Spacing-Skala, semantische Farben, Radien und
// wiederverwendbare Bausteine (Glass-Chips, Icon-Buttons). Kein View nutzt mehr Ad-hoc-
// Werte wie `opacity(0.08)` oder hartkodierte Abstände für Flächen, die das System kennt.
//
// Dark/Light: Alle Farbtokens sind von Systemfarben abgeleitet (keine Hex-Werte), damit
// Dark Mode und "Transparenz reduzieren" automatisch korrekt bleiben.

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
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 14
        static let extraLarge: CGFloat = 18
    }

    // MARK: Semantische Farben

    enum Ink {
        /// Primäre Textfarbe (folgt Light/Dark automatisch).
        static let primary = Color.primary
        /// Sekundäre Textfarbe für Labels, Hints, Captions.
        static let secondary = Color.secondary
        /// Haarlinien / Trennlinien.
        static let hairline = Color(nsColor: .separatorColor)
        /// Akzent der App (App-Catalog-Akzent).
        static let accent = Color.accentColor
        /// Lern-/Quiz-Assoziation der App.
        static let quiz = Color.purple
        /// Dokument-/Import-Assoziation.
        static let document = Color.blue
    }

    // MARK: Flächen

    enum Surface {
        /// Hintergrundfläche für Nachrichten-Chips, Popover-Zeilen etc. – subtil, ohne Deckkraft-Konkurrenz zum Vibrancy-Hintergrund.
        static let chip = Color.primary.opacity(0.05)
        /// Hover-Variante derselben Fläche.
        static let chipHover = Color.primary.opacity(0.09)
        /// Getönte Nutzer-Bubble (Chat-Nachricht vom Nutzer).
        static let bubbleUser = Color.accentColor.opacity(0.10)
        /// Hintergrund der Metrik-/Status-Chips (etwas sichtbarer als .chip).
        static let status = Color.primary.opacity(0.08)
        /// Ruhige Karte für Konfiguration und sekundäre Informationen.
        static let card = Color(nsColor: .controlBackgroundColor).opacity(0.82)
        /// Subtil abgesetzte Navigation, ohne den Content zu dominieren.
        static let navigation = Color.primary.opacity(0.035)
        /// Selektionsfarbe für eigene Navigationszeilen.
        static let selection = Color.accentColor.opacity(0.14)
    }
}

// MARK: - Surface-Bausteine

/// Einheitliche Karte für ruhige, informationsreiche Bereiche. Der Rand bleibt bewusst fein,
/// damit die Oberfläche auch bei aktivierter Transparenzreduktion klar gegliedert ist.
struct AppCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(DS.Space.l)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                    .fill(DS.Surface.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                    .stroke(DS.Ink.hairline.opacity(0.55), lineWidth: 0.5)
            )
    }
}

// MARK: - GlassChip
//
// Wiederverwendbarer Liquid-Glass-Chip für die funktionale Ebene (Header-Buttons,
// Status-Chips). Auf macOS 26+ nutzt er das echte glassEffect; die Inhalte bleiben
// opak und lesbar. Glass gehört NUR auf Steuerflächen, nie auf Chat-Content (Kernregel
// der Tahoe-Designsprache).

struct GlassChip<Content: View>: View {
    @Environment(\.controlActiveState) private var controlActiveState
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .glassEffect(.regular, in: Capsule())
            .opacity(controlActiveState == .inactive ? 0.6 : 1.0)
    }
}

/// Icon-Button auf Glass (Header: Einstellungen, Teilen, …).
struct GlassIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: Circle())
        .help(help)
    }
}

/// Teilen-Button im Safari-Stil, auf Glass. Bekommt einen LAZY Provider statt des Strings
/// selbst (Perf-Audit K2): Der Chat-Markdown wird erst beim Klick gebaut – vorher baute ihn
/// ShareLink bei jedem Body-Eval (d.h. ~5x/s während des Streamings + pro Tastendruck) neu,
/// O(Chat-Länge) pro Render.
struct GlassShareButton: View {
    let provideItem: () -> String
    let help: String

    var body: some View {
        Button {
            Self.showSharePicker(for: provideItem())
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: Circle())
        .help(help)
    }

    /// Öffnet den System-Share-Picker (wie Safari): Mail, Notizen, AirDrop usw.
    static func showSharePicker(for text: String) {
        guard !text.isEmpty,
              let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }),
              let contentView = panel.contentView else { return }
        let picker = NSSharingServicePicker(items: [text])
        // Anker oben rechts (Panel-Koordinaten, contentView ist geflippt).
        let rect = NSRect(x: contentView.bounds.width - 240, y: 48, width: 12, height: 12)
        picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
    }
}
