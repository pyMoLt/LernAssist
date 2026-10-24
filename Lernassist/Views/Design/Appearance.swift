import AppKit
import SwiftUI

// MARK: - Darstellung (Version 4, „Flow“ nach der NativeTongue-Vorlage)

/// Akzentfarbe der Oberfläche: Auswahl, Schalter, Knöpfe, Nutzer-Nachrichten, Farbfeld.
nonisolated enum AppearanceAccent: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, violet, indigo, ocean, teal, coral, rose, graphite

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: L("System")
        case .violet: L("Violett")
        case .indigo: L("Indigo")
        case .ocean: L("Ozean")
        case .teal: L("Türkis")
        case .coral: L("Koralle")
        case .rose: L("Rosé")
        case .graphite: L("Graphit")
        }
    }

    /// (hell, dunkel) – im Dunkelmodus heller, damit Text und Symbole lesbar bleiben.
    fileprivate var rgb: (light: (Double, Double, Double), dark: (Double, Double, Double))? {
        switch self {
        case .system: nil
        case .violet: ((0.45, 0.27, 0.86), (0.70, 0.58, 1.00))
        case .indigo: ((0.31, 0.33, 0.88), (0.57, 0.60, 1.00))
        case .ocean: ((0.00, 0.47, 0.84), (0.36, 0.68, 1.00))
        case .teal: ((0.00, 0.55, 0.55), (0.27, 0.78, 0.75))
        case .coral: ((0.93, 0.36, 0.31), (1.00, 0.56, 0.50))
        case .rose: ((0.86, 0.24, 0.51), (1.00, 0.49, 0.69))
        case .graphite: ((0.32, 0.33, 0.37), (0.80, 0.81, 0.84))
        }
    }
}

/// Wie stark Flächen durchscheinen.
nonisolated enum AppearanceGlass: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Liquid Glass wie von macOS gezeichnet – am durchsichtigsten.
    case clear
    /// Milchglas: deckender, ruhiger zu lesen.
    case frosted
    /// Deckende Flächen ohne Transparenz.
    case solid

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .clear: L("Klar")
        case .frosted: L("Milchig")
        case .solid: L("Deckend")
        }
    }
    var help: String {
        switch self {
        case .clear: L("Liquid Glass, wie macOS es zeichnet – am durchsichtigsten.")
        case .frosted: L("Milchglas: etwas deckender und ruhiger zu lesen.")
        case .solid: L("Deckende Flächen ohne Transparenz.")
        }
    }
}

/// Weiches Farbfeld hinter den Fenstern.
nonisolated enum AppearanceBackground: String, Codable, CaseIterable, Identifiable, Sendable {
    case vivid, subtle, off

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .vivid: L("Kräftig")
        case .subtle: L("Dezent")
        case .off: L("Aus")
        }
    }
    var intensity: Double {
        switch self {
        case .vivid: 1
        case .subtle: 0.45
        case .off: 0
        }
    }
}

/// Animierte Übergänge (Seitenwechsel, Auswahl, Ein-/Ausklappen).
nonisolated enum AppearanceMotion: String, Codable, CaseIterable, Identifiable, Sendable {
    case fluid, reduced

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .fluid: L("Fließend")
        case .reduced: L("Reduziert")
        }
    }
}

/// Aussehen der App. Farbschema und Schriftgröße im Chat liegen weiter in eigenen Feldern
/// (`appTheme`, `chatFontSize`), damit ältere Einstellungen unverändert gelten.
nonisolated struct AppearanceSettings: Codable, Equatable, Sendable {
    var accent: AppearanceAccent = .violet
    var glass: AppearanceGlass = .frosted
    var background: AppearanceBackground = .subtle
    var motion: AppearanceMotion = .fluid

    init() {}

    private enum CodingKeys: String, CodingKey { case accent, glass, background, motion }

    /// Fehlende oder unbekannte Werte fallen auf den Standard zurück.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppearanceSettings()
        accent = (try? c.decodeIfPresent(AppearanceAccent.self, forKey: .accent)) ?? d.accent
        glass = (try? c.decodeIfPresent(AppearanceGlass.self, forKey: .glass)) ?? d.glass
        background = (try? c.decodeIfPresent(AppearanceBackground.self, forKey: .background)) ?? d.background
        motion = (try? c.decodeIfPresent(AppearanceMotion.self, forKey: .motion)) ?? d.motion
    }
}

// MARK: - Aktuelle Darstellung (global, für DS-Farben)

/// Die gerade gültige Darstellung. Wird vom ViewModel gesetzt; die Wurzel-Views bauen sich bei
/// einer Änderung neu auf (`.appAppearance`), damit alle DS-Farben den neuen Akzent lesen.
nonisolated enum Theme {
    nonisolated(unsafe) static var current = AppearanceSettings()

    static func accentNSColor(_ accent: AppearanceAccent) -> NSColor {
        guard let rgb = accent.rgb else { return .controlAccentColor }
        return NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb.dark : rgb.light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        }
    }

    /// Kräftige Fassung für Flächen und Verläufe (auch im Dunkelmodus satt).
    static func solidNSColor(_ accent: AppearanceAccent) -> NSColor {
        guard let rgb = accent.rgb else { return .controlAccentColor }
        return NSColor(srgbRed: rgb.light.0, green: rgb.light.1, blue: rgb.light.2, alpha: 1)
    }

    static var accent: Color { Color(nsColor: accentNSColor(current.accent)) }
    static var accentSolid: Color { Color(nsColor: solidNSColor(current.accent)) }

    /// Begleitfarbe für Verläufe und das Farbfeld (etwas wärmer bzw. kühler als der Akzent).
    static func companion(_ accent: AppearanceAccent) -> Color {
        switch accent {
        case .violet: Color(red: 0.93, green: 0.45, blue: 0.72)
        case .indigo: Color(red: 0.55, green: 0.42, blue: 0.95)
        case .ocean: Color(red: 0.25, green: 0.80, blue: 0.85)
        case .teal: Color(red: 0.40, green: 0.82, blue: 0.55)
        case .coral: Color(red: 0.98, green: 0.62, blue: 0.48)
        case .rose: Color(red: 0.72, green: 0.40, blue: 0.95)
        case .graphite: Color(red: 0.62, green: 0.64, blue: 0.70)
        case .system: Color(nsColor: .controlAccentColor).opacity(0.7)
        }
    }

    static func gradient(_ accent: AppearanceAccent) -> LinearGradient {
        LinearGradient(colors: [companion(accent), Color(nsColor: solidNSColor(accent))],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Farbfeld

/// Weiche, ruhende Farbflecken hinter dem Inhalt (keine Animation – im Leerlauf kostet das nichts).
struct ColorFieldBackground: View {
    let accent: AppearanceAccent
    let background: AppearanceBackground
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let strength = background.intensity * (colorScheme == .dark ? 0.55 : 1)
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if strength > 0 {
                    blob(Theme.companion(accent), x: 0.12, y: 0.08, scale: 0.9, opacity: 0.55 * strength, in: size)
                    blob(Color(nsColor: Theme.solidNSColor(accent)), x: 0.92, y: 0.18, scale: 0.75, opacity: 0.35 * strength, in: size)
                    blob(Theme.companion(accent), x: 0.78, y: 0.95, scale: 1.0, opacity: 0.40 * strength, in: size)
                    blob(Color(red: 1.0, green: 0.85, blue: 0.75), x: 0.25, y: 0.85, scale: 0.7, opacity: 0.30 * strength, in: size)
                }
            }
            .compositingGroup()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func blob(_ color: Color, x: CGFloat, y: CGFloat, scale: CGFloat, opacity: Double, in size: CGSize) -> some View {
        let diameter = max(size.width, size.height) * scale
        return Circle()
            .fill(color.opacity(opacity))
            .frame(width: diameter, height: diameter)
            .position(x: size.width * x, y: size.height * y)
            .blur(radius: diameter * 0.28)
    }
}

// MARK: - Glas-Flächen

private struct GlassKey: EnvironmentKey { static let defaultValue: AppearanceGlass = .frosted }

extension EnvironmentValues {
    var appGlass: AppearanceGlass {
        get { self[GlassKey.self] }
        set { self[GlassKey.self] = newValue }
    }
}

/// Fläche für Karten, Pillen und schwebende Leisten – je nach Einstellung Liquid Glass,
/// Milchglas oder deckend.
struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    var elevated: Bool = false
    @Environment(\.appGlass) private var glass
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        switch glass {
        case .clear:
            content.glassEffect(.regular, in: shape)
        case .frosted:
            content
                .background(shape.fill(.regularMaterial))
                .background(shape.fill(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.35 : 0.55)))
                .overlay(shape.strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.55), lineWidth: 0.75))
                .shadow(color: .black.opacity(elevated ? 0.10 : 0.04), radius: elevated ? 14 : 6, y: elevated ? 4 : 2)
        case .solid:
            content
                .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(shape.strokeBorder(DS.Ink.hairline, lineWidth: 0.75))
                .shadow(color: .black.opacity(elevated ? 0.08 : 0.03), radius: elevated ? 10 : 4, y: elevated ? 3 : 1)
        }
    }
}

extension View {
    func glassSurface<S: InsettableShape>(_ shape: S, elevated: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, elevated: elevated))
    }

    func glassSurface(cornerRadius: CGFloat = DS.Radius.pill, elevated: Bool = false) -> some View {
        modifier(GlassSurface(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), elevated: elevated))
    }

    /// Wendet die Darstellung auf eine Fenster-Wurzel an: Akzent als Tint, Glas für alle Flächen,
    /// reduzierte Bewegung und Neuaufbau bei Akzentwechsel.
    func appAppearance(_ appearance: AppearanceSettings, language: AppLanguage = Loc.current) -> some View {
        self
            .tint(Theme.accent)
            .environment(\.appGlass, appearance.glass)
            .transaction { transaction in
                if appearance.motion == .reduced {
                    transaction.disablesAnimations = true
                    transaction.animation = nil
                }
            }
            .environment(\.locale, Locale(identifier: language == .english ? "en_US" : "de_DE"))
            // Neuaufbau bei Akzent- oder Sprachwechsel: alle DS-Farben und L(…)-Texte neu lesen.
            .id("\(appearance.accent.rawValue)-\(language.rawValue)")
    }
}

// MARK: - Pillen-Auswahl

/// Segmentierte Auswahl im Pillen-Stil (Vorlage): Kapsel, gewählte Option mit Akzentfläche.
struct PillPicker<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    var symbol: ((Value) -> String?)? = nil
    var compact = false
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = option }
                } label: {
                    HStack(spacing: 5) {
                        if let name = symbol?(option) { Image(systemName: name).font(.system(size: 11, weight: .medium)) }
                        Text(label(option))
                    }
                    .font(.system(size: compact ? 11.5 : 12.5, weight: isSelected ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.85))
                    .padding(.horizontal, compact ? 9 : 13)
                    .padding(.vertical, compact ? 4 : 6)
                    .background {
                        if isSelected {
                            Capsule().fill(Theme.accentSolid).matchedGeometryEffect(id: "pill", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .overlay(Capsule().strokeBorder(DS.Ink.hairline, lineWidth: 0.75))
    }
}

/// Farbkreise für die Akzentwahl (Vorlage: Kreis mit Verlauf, Haken bei Auswahl).
struct AccentSwatchPicker: View {
    @Binding var selection: AppearanceAccent

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppearanceAccent.allCases) { accent in
                let isSelected = accent == selection
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = accent }
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(accent == .system
                                      ? AnyShapeStyle(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red], center: .center))
                                      : AnyShapeStyle(Theme.gradient(accent)))
                                .frame(width: 30, height: 30)
                            if isSelected {
                                Circle().strokeBorder(Color.white, lineWidth: 2).frame(width: 30, height: 30)
                                Circle().strokeBorder(Color(nsColor: Theme.solidNSColor(accent)), lineWidth: 2).frame(width: 36, height: 36)
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 38, height: 38)
                        Text(accent.displayName)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular, design: .rounded))
                            .foregroundStyle(isSelected ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(accent.displayName)
                .accessibilityLabel(L("Akzentfarbe \(accent.displayName)"))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}
