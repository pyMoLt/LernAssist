import SwiftUI

// MARK: - AppearanceTabView

struct AppearanceTabView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            settingsSection(icon: "paintpalette.fill", title: "Erscheinungsbild & Typografie", tint: DS.Accent.cyan) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    SettingsRow(
                        title: "Farbschema",
                        subtitle: "Wähle zwischen System-Automatik, hellem oder dunklem Modus.",
                        icon: "circle.lefthalf.filled",
                        tint: DS.Accent.indigo
                    ) {
                        HStack(spacing: 2) {
                            ForEach([("System", "System"), ("Light", "Hell"), ("Dark", "Dunkel")], id: \.0) { tag, label in
                                let isSelected = viewModel.appTheme == tag
                                Button {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        viewModel.appTheme = tag
                                    }
                                } label: {
                                    Text(label)
                                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium, design: .rounded))
                                        .foregroundStyle(isSelected ? DS.Ink.accent : .secondary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 5)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .fill(isSelected ? DS.Surface.selection : .clear)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(3)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                                .fill(DS.Surface.control)
                        )
                        .settingHelp("Wechselt das Design zwischen hellem und dunklem Modus oder folgt den System-Einstellungen.")
                    }

                    SettingsHairline()

                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        HStack {
                            Text("Schriftgröße im Chat")
                                .font(.system(.subheadline, design: .rounded).weight(.medium))
                            Spacer()
                            Text("\(Int(viewModel.chatFontSize * 100)) %")
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                                .foregroundStyle(DS.Accent.indigo)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Surface.control))
                        }

                        HStack(spacing: DS.Space.m) {
                            Text("A")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                            Slider(value: $viewModel.chatFontSize, in: 0.8...1.5, step: 0.05)
                                .tint(DS.Accent.indigo)
                            Text("A")
                                .font(.system(size: 19, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        .settingHelp("Skaliert die Größe des Textes im Chat-Verlauf fließend.")

                        Text("Beispieltext in der gewählten Schriftgröße (\(Int(14 * viewModel.chatFontSize)) pt)")
                            .font(.system(size: 14 * viewModel.chatFontSize))
                            .padding(DS.Space.m)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous).fill(DS.Surface.control))
                    }
                }
            }

            settingsSection(icon: "macwindow", title: "Fenster- & Systemverhalten", tint: DS.Accent.indigo) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    SettingsRow(
                        title: "Dock-Icon ausblenden (Nur-Menüleiste)",
                        subtitle: "LernAssist läuft dezent im Hintergrund und wird per Hotkey oder Menüleiste geöffnet.",
                        icon: "dock.rectangle",
                        tint: DS.Accent.indigo
                    ) {
                        Toggle("", isOn: $viewModel.isMenuBarApp)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .settingHelp("Wenn aktiviert, erscheint LernAssist nicht mehr im Dock – nur noch per globalem Hotkey oder Menüleisten-Symbol erreichbar.")
                    }

                    SettingsHairline()

                    SettingsRow(
                        title: "Menüleisten-Symbol anzeigen",
                        subtitle: "Zeigt ein Schnellzugriffs-Symbol oben rechts in der macOS-Menüleiste.",
                        icon: "menubar.rectangle",
                        tint: DS.Accent.cyan
                    ) {
                        Toggle("", isOn: $viewModel.showMenuBarIcon)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .settingHelp("Zeigt zusätzlich ein Symbol in der Mac-Menüleiste, unabhängig vom Dock-Icon.")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
