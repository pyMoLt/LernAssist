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
        HStack(spacing: DS.Space.s) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint.opacity(0.14))
                .frame(width: 22, height: 22)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                )

            Text(title)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)

            Spacer()
            trailing()
        }
        .padding(.horizontal, 2)

        AppCard {
            content()
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
        .padding(.vertical, 3)
    }

    private var label: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            if let icon {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.13))
                    .frame(width: 26, height: 26)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(tint)
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
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
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tint.opacity(0.14))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Image(systemName: icon)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(tint)
                        )

                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(.primary)
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        Text(isExpanded ? "Ausblenden" : "Einblenden")
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
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
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

