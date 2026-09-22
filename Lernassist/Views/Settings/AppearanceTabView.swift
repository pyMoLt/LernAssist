import SwiftUI

// MARK: - AppearanceTabView

struct AppearanceTabView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        // Kein `Form` innerhalb der ScrollView von SettingsView: native Forms können beim
        // Tabwechsel auf macOS 26 als leere, verschobene Fläche enden (siehe AdvancedTabView).
        VStack(alignment: .leading, spacing: 20) {
            settingsSection(icon: "paintpalette", title: "Erscheinungsbild") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Farbschema", selection: $viewModel.appTheme) {
                        Text("System").tag("System")
                        Text("Hell").tag("Light")
                        Text("Dunkel").tag("Dark")
                    }
                    .pickerStyle(.segmented)
                    .settingHelp("Wechselt das Design zwischen hellem und dunklem Modus oder folgt den System-Einstellungen.")

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Schriftgröße im Chat")
                            Spacer()
                            Text("\(Int(viewModel.chatFontSize * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        HStack(spacing: 10) {
                            Text("A").font(.system(size: 11))
                            Slider(value: $viewModel.chatFontSize, in: 0.8...1.5, step: 0.05)
                            Text("A").font(.system(size: 20))
                        }
                        .settingHelp("Skaliert die Größe des Textes im Chat-Verlauf fließend.")

                        Text("Beispieltext in der aktuellen Größe")
                            .font(.system(size: 14 * viewModel.chatFontSize))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.08))
                            .cornerRadius(6)
                    }
                }
            }

            settingsSection(icon: "switch.2", title: "Verhalten") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Dock-Icon ausblenden", isOn: $viewModel.isMenuBarApp)
                        .settingHelp("Wenn aktiviert, erscheint LernAssist nicht mehr im Dock – nur noch per globalem Hotkey oder Menüleisten-Symbol erreichbar. Wirkt sofort, kein Neustart nötig.")

                    Toggle("Menüleisten-Symbol anzeigen", isOn: $viewModel.showMenuBarIcon)
                        .settingHelp("Zeigt zusätzlich ein Symbol in der Mac-Menüleiste, unabhängig vom Dock-Icon. Wirkt sofort, kein Neustart nötig.")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
