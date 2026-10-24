import SwiftUI

// MARK: - AppearanceTabView (Version 4, nach der NativeTongue-Vorlage)

struct AppearanceTabView: View {
    @ObservedObject var viewModel: ChatViewModel

    /// Feste Stufen für die Schrift im Chat (statt Schieberegler, wie in der Vorlage).
    private static let textSizes: [(label: String, scale: Double)] = [
        ("XS", 0.85), ("S", 0.92), ("M", 1.0), ("L", 1.12), ("XL", 1.25), ("XXL", 1.4)
    ]

    private var textSizeBinding: Binding<Double> {
        Binding(
            get: {
                let current = viewModel.chatFontSize
                return Self.textSizes.min { abs($0.scale - current) < abs($1.scale - current) }?.scale ?? 1
            },
            set: { viewModel.chatFontSize = $0 }
        )
    }

    private func appearanceBinding<T>(_ keyPath: WritableKeyPath<AppearanceSettings, T>) -> Binding<T> {
        Binding(get: { viewModel.appearance[keyPath: keyPath] },
                set: { viewModel.appearance[keyPath: keyPath] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            settingsSection(icon: "circle.lefthalf.filled", title: L("Anzeige")) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    // Sprache bewusst zweisprachig beschriftet – so findet man sie in jeder Sprache.
                    SettingsRow(title: "Language · Sprache",
                                subtitle: L("Sprache der Oberfläche. Antworten des Modells richten sich nach deiner Frage.")) {
                        PillPicker(options: AppLanguage.allCases, selection: $viewModel.appLanguage, label: \.nativeName)
                    }

                    SettingsHairline()

                    SettingsRow(title: L("Erscheinungsbild"),
                                subtitle: L("System folgt der Hell-/Dunkel-Einstellung deines Macs.")) {
                        PillPicker(options: ["System", "Light", "Dark"], selection: $viewModel.appTheme,
                                   label: { ["System": L("System"), "Light": L("Hell"), "Dark": L("Dunkel")][$0] ?? $0 },
                                   symbol: { ["System": "circle.lefthalf.filled", "Light": "sun.max", "Dark": "moon"][$0] })
                            .settingHelp(L("Wechselt zwischen hellem und dunklem Modus oder folgt dem System."))
                    }

                    SettingsHairline()

                    SettingsRow(title: L("Schriftgröße im Chat"),
                                subtitle: L("Antworten und Eingabe; Formeln und Diagramme wachsen mit.")) {
                        PillPicker(options: Self.textSizes.map(\.scale), selection: textSizeBinding,
                                   label: { scale in Self.textSizes.first { $0.scale == scale }?.label ?? "M" }, compact: true)
                            .settingHelp(L("Skaliert den Text im Chat-Verlauf."))
                    }
                }
            }

            settingsSection(icon: "paintpalette", title: L("Akzentfarbe")) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    AccentSwatchPicker(selection: appearanceBinding(\.accent))
                        .settingHelp(L("Farbe für Auswahl, Schalter, Knöpfe, deine Nachrichten und das Farbfeld."))
                }
            }
            Text(L("Für Auswahl, Schalter, Knöpfe, deine Nachrichten und das Farbfeld. „Graphit“ mit „Deckend“ und Farbfeld „Aus“ ergibt den schlichten Schwarz-Weiß-Look."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, DS.Space.m)
                .padding(.top, -DS.Space.s)

            settingsSection(icon: "square.on.square", title: L("Flächen")) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    SettingsRow(title: L("Glas"), subtitle: viewModel.appearance.glass.help) {
                        PillPicker(options: AppearanceGlass.allCases, selection: appearanceBinding(\.glass),
                                   label: \.displayName)
                            .settingHelp(L("Wie stark Karten, Leisten und Eingabefeld durchscheinen."))
                    }

                    SettingsHairline()

                    SettingsRow(title: L("Farbfeld"), subtitle: L("Die weichen Farben hinter den Fenstern.")) {
                        PillPicker(options: AppearanceBackground.allCases, selection: appearanceBinding(\.background),
                                   label: \.displayName)
                            .settingHelp(L("Farbflecken in der Akzentfarbe hinter dem Inhalt. Sie bewegen sich nicht und kosten im Leerlauf keine Leistung."))
                    }
                }
            }

            settingsSection(icon: "wind", title: L("Bewegung")) {
                SettingsRow(title: L("Übergänge"),
                            subtitle: L("Farben und Auswahl gleiten ineinander. Ohne Bedienung bewegt sich nichts.")) {
                    PillPicker(options: AppearanceMotion.allCases, selection: appearanceBinding(\.motion),
                               label: \.displayName)
                        .settingHelp(L("„Reduziert“ schaltet Animationen beim Wechseln, Ein- und Ausklappen ab."))
                }
            }

            settingsSection(icon: "macwindow", title: L("Fenster & System")) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    SettingsRow(
                        title: L("Dock-Icon ausblenden (Nur-Menüleiste)"),
                        subtitle: L("LernAssist läuft dezent im Hintergrund und wird per Hotkey oder Menüleiste geöffnet.")
                    ) {
                        Toggle("", isOn: $viewModel.isMenuBarApp)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .settingHelp(L("Wenn aktiviert, erscheint LernAssist nicht mehr im Dock – nur noch per globalem Hotkey oder Menüleisten-Symbol erreichbar."))
                    }

                    SettingsHairline()

                    SettingsRow(
                        title: L("Menüleisten-Symbol anzeigen"),
                        subtitle: L("Zeigt ein Schnellzugriffs-Symbol oben rechts in der macOS-Menüleiste.")
                    ) {
                        Toggle("", isOn: $viewModel.showMenuBarIcon)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .settingHelp(L("Zeigt zusätzlich ein Symbol in der Mac-Menüleiste, unabhängig vom Dock-Icon."))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
