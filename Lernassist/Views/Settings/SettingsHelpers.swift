import SwiftUI

// MARK: - Gemeinsame Layout- & Control-Helfer für alle Settings-Tabs (Design 2.0)

@ViewBuilder
func settingsSection<Content: View, Trailing: View>(
    icon: String,
    title: String,
    tint: Color = DS.Accent.brand,
    @ViewBuilder trailing: () -> Trailing,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: DS.Space.s) {
        // Version 4: schlichte graue Abschnittsüberschrift (Vorlage), Symbol nur für Bedienhilfen.
        HStack(spacing: DS.Space.s) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing()
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.top, DS.Space.s)
        .modifier(SearchHighlight(title: title))

        // Inhalt immer gebündelt: Lose Elemente bekämen sonst jedes einen eigenen Kartenhintergrund
        // (Trennlinien erschienen als leere Kärtchen).
        AppCard {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@ViewBuilder
func settingsSection<Content: View>(
    icon: String,
    title: String,
    tint: Color = DS.Accent.brand,
    @ViewBuilder content: () -> Content
) -> some View {
    settingsSection(icon: icon, title: title, tint: tint, trailing: { EmptyView() }, content: content)
}

@ViewBuilder
func labeledField<Content: View>(_ label: String, isModified: Bool = false, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        Text(label)
            .font(.system(size: 11.5, weight: isModified ? .semibold : .medium, design: .rounded))
            .foregroundStyle(isModified ? DS.Ink.accent : .secondary)
        content()
    }
    .modifier(SearchHighlight(title: label))
}

// MARK: - Suche in den Einstellungen

private struct SettingsHighlightKey: EnvironmentKey { static let defaultValue: String? = nil }
private struct SettingsHighlightSectionKey: EnvironmentKey { static let defaultValue: String? = nil }

extension EnvironmentValues {
    /// Titel (in der aktuellen Sprache) der Einstellung, zu der die Suche gerade springt.
    var settingsHighlight: String? {
        get { self[SettingsHighlightKey.self] }
        set { self[SettingsHighlightKey.self] = newValue }
    }
    /// Aufklappbarer Abschnitt (aktuelle Sprache), der für das Sprungziel geöffnet werden muss.
    var settingsHighlightSection: String? {
        get { self[SettingsHighlightSectionKey.self] }
        set { self[SettingsHighlightSectionKey.self] = newValue }
    }
}

/// Markiert eine Einstellung als Sprungziel der Suche (ID zum Scrollen + kurze Hervorhebung).
struct SearchHighlight: ViewModifier {
    let title: String
    @Environment(\.settingsHighlight) private var highlight

    func body(content: Content) -> some View {
        content
            .id("setting-" + title)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DS.Accent.brand.opacity(highlight == title ? 0.16 : 0))
                    .padding(-6)
                    .animation(.easeInOut(duration: 0.3), value: highlight)
            )
    }
}

/// Einheitliche Einstellungs-Zeile: Links Label (+ optionale Unterzeile & Icon), rechts das Control
/// exakt auf einer Achse ausgerichtet (verhindert Versatz zwischen verschiedenen Control-Typen).
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    var tint: Color = DS.Accent.brand
    /// Ausführlichere Erklärung für den Info-Modus (sonst Titel + Untertitel).
    var help: String? = nil
    @ViewBuilder let control: () -> Control

    private var helpText: String {
        if let help { return help }
        if let subtitle, !subtitle.isEmpty { return "\(title): \(subtitle)" }
        return title
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            // Info-Modus: Erklärung beim Überfahren von Titel/Untertitel (das Bedienelement
            // kann eine eigene, genauere Erklärung haben – ohne Überlappung).
            label
                .settingHelp(helpText)

            Spacer(minLength: DS.Space.m)

            control()
        }
        .padding(.vertical, 5)
        .modifier(SearchHighlight(title: title))
    }

    private var label: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            // Version 4: Zeilen wie in der Vorlage ohne Symbol-Kachel – Text links, Bedienelement rechts.
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Subtile Trennlinie innerhalb einer Settings-Karte (ersetzt harte System-Divider).
struct SettingsHairline: View {
    var body: some View {
        Rectangle()
            .fill(DS.Ink.hairline)
            .frame(height: 0.75)
            .padding(.vertical, 4)
    }
}

/// Rahmenloses, ruhiges TextField-/SecureField-Styling ohne schwarze AppKit-Kontrast-Ränder.
struct SettingsFieldStyle: ViewModifier {
    var monospaced: Bool = false

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(monospaced ? .system(size: 12.5, design: .monospaced) : .system(size: 12.5, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .fill(DS.Surface.control)
            )
    }
}

/// Sanfter Pill-/Action-Button für Settings (ersetzt `.buttonStyle(.bordered)` ohne schwarze System-Umrandung).
struct SoftActionButtonStyle: ButtonStyle {
    var tint: Color = DS.Accent.brand
    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(prominent ? Color.white : tint)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .fill(
                        prominent
                            ? AnyShapeStyle(DS.Accent.brandGradient)
                            : AnyShapeStyle(tint.opacity(configuration.isPressed ? 0.20 : 0.12))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .stroke(prominent ? Color.clear : tint.opacity(0.22), lineWidth: 0.75)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
    }
}

/// Rahmenloses Ausklapp-Menü (ersetzt `Picker(...).pickerStyle(.menu)` ohne schwarze AppKit-Kontrastränder).
struct SoftDropdownMenu<MenuContent: View>: View {
    let label: String
    var icon: String? = nil
    var iconTint: Color = DS.Accent.indigo
    var width: CGFloat? = nil
    @ViewBuilder let menuContent: () -> MenuContent

    var body: some View {
        Menu {
            menuContent()
        } label: {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(iconTint)
                        .frame(width: 15)
                }
                Text(label)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: width, alignment: .leading)
            .frame(minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .fill(DS.Surface.control)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Eingeklappter „Erweitert“-Bereich für Einstellungs-Tabs.
struct SettingsDisclosureSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var icon: String = "slider.horizontal.2.square"
    var tint: Color = DS.Accent.indigo
    var help: String? = nil
    @State private var isExpanded: Bool = false
    @ViewBuilder let content: () -> Content
    @Environment(\.settingsHighlightSection) private var highlightSection

    private var headerHelp: String {
        if let help { return help }
        if let subtitle, !subtitle.isEmpty { return "\(title): \(subtitle)" }
        return title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: DS.Space.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 13.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.primary)
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        Text(isExpanded ? L("Ausblenden") : L("Einblenden"))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(DS.Surface.control))
                }
                .padding(.horizontal, DS.Space.l + 2)
                .padding(.vertical, DS.Space.m)
                .contentShape(Rectangle())
                .glassSurface(cornerRadius: DS.Radius.pill)
                .settingHelp(headerHelp)
            }
            .buttonStyle(.plain)

            if isExpanded {
                AppCard {
                    content()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .modifier(SearchHighlight(title: title))
        .onAppear { if highlightSection == title { isExpanded = true } }
        .onChange(of: highlightSection) { _, section in
            if section == title { withAnimation(.easeInOut(duration: 0.18)) { isExpanded = true } }
        }
    }
}

@ViewBuilder
func stepperBadge<V: Strideable>(_ text: String, value: Binding<V>, range: ClosedRange<V>, step: V.Stride = 1) -> some View {
    HStack(spacing: DS.Space.s) {
        Text(text)
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .foregroundStyle(DS.Accent.indigo)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Surface.control))
        Stepper("", value: value, in: range, step: step)
            .labelsHidden()
    }
}

