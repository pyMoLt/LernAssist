import SwiftUI

// MARK: - AdvancedTabView

struct AdvancedTabView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var showResetConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            settingsSection(icon: "lock.shield.fill", title: "Einrichtung & Berechtigungen", tint: DS.Accent.emerald) {
                SettingsRow(
                    title: "Einrichtungs-Assistent",
                    subtitle: "Rolle dieses Macs, Verbindung zu oMLX, Recherche und Berechtigungen in fünf Schritten.",
                    icon: "wand.and.stars",
                    tint: DS.Accent.emerald
                ) {
                    Button("Assistent starten") {
                        NotificationCenter.default.post(name: .showSetupAssistant, object: nil)
                    }
                    .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.emerald, prominent: true))
                    .settingHelp("Führt durch die komplette Einrichtung – z. B. auf einem Gerät, das die Modelle eines Servers im Netzwerk nutzt. Bestehende Chats bleiben unberührt.")
                }

                SettingsHairline()

                SettingsRow(
                    title: "Berechtigungs-Assistent",
                    subtitle: "Prüft Zugriffs-Hilfen („Auswahl erklären“) und Bildschirmaufnahme (Screenshots) mit Live-Status.",
                    icon: "checkmark.shield.fill",
                    tint: DS.Accent.emerald
                ) {
                    Button("Assistent öffnen") {
                        NotificationCenter.default.post(name: .showPermissionOnboarding, object: nil)
                    }
                    .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.emerald, prominent: true))
                    .settingHelp("Zeigt das Berechtigungs-Fenster erneut – nützlich nach Updates oder wenn ein Hotkey still nichts tut.")
                }
            }

            settingsSection(icon: "archivebox.fill", title: "Chats", tint: DS.Accent.blue) {
                SettingsRow(
                    title: "Automatisch archivieren",
                    subtitle: "Chats ohne Aktivität wandern ins Archiv (Sidebar unten → Archiv) und bleiben dort lesbar.",
                    icon: "clock.arrow.circlepath",
                    tint: DS.Accent.blue
                ) {
                    Picker("", selection: $viewModel.autoArchiveDays) {
                        Text("nach 7 Tagen").tag(7)
                        Text("nach 14 Tagen").tag(14)
                        Text("nach 30 Tagen").tag(30)
                        Text("nach 90 Tagen").tag(90)
                        Text("nie").tag(0)
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .settingHelp("Wird beim App-Start geprüft. Karteikarten archivierter Chats bleiben in der Wiederholung.")
                }
            }

            settingsSection(icon: "gearshape.2.fill", title: "Hintergrundprozesse", tint: DS.Accent.indigo) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    SettingsRow(
                        title: "Automatische Chat-Titel (Auto-Labeling)",
                        subtitle: "Erstellt nach der ersten Antwort im Hintergrund einen prägnanten Titel.",
                        icon: "tag.fill",
                        tint: DS.Accent.indigo
                    ) {
                        Toggle("", isOn: $viewModel.autoLabelingEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    SettingsHairline()

                    SettingsRow(
                        title: "Bild-zu-Text-Konvertierung im Hintergrund",
                        subtitle: "Wandelt ältere Screenshots in Textbeschreibungen um, um KV-Cache zu sparen.",
                        icon: "text.viewfinder",
                        tint: DS.Accent.cyan
                    ) {
                        Toggle("", isOn: $viewModel.autoImageToTextEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    SettingsHairline()

                    SettingsRow(
                        title: "Eingebettete Bilder aus Dokumenten analysieren",
                        subtitle: "Beschreibt Folien und Abbildungen aus PDFs/Word/PowerPoint per Vision-Modell.",
                        icon: "doc.viewfinder",
                        tint: DS.Accent.amber
                    ) {
                        Toggle("", isOn: $viewModel.extractImagesFromPDF)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    if viewModel.extractImagesFromPDF {
                        SettingsRow(
                            title: "Detailgrad der Bildextraktion",
                            subtitle: "Bestimmt die Ausführlichkeit der Bildbeschreibungen.",
                            icon: "slider.horizontal.below.rectangle",
                            tint: DS.Accent.amber
                        ) {
                            SoftDropdownMenu(
                                label: viewModel.imageExtractionDetail,
                                width: 195
                            ) {
                                ForEach([
                                    ("Kurz", "Kurz (Ressourcenschonend)"),
                                    ("Normal", "Normal"),
                                    ("Detailliert", "Detailliert (Mehr Tokens)")
                                ], id: \.0) { tag, title in
                                    Button {
                                        viewModel.imageExtractionDetail = tag
                                    } label: {
                                        if viewModel.imageExtractionDetail == tag {
                                            Label(title, systemImage: "checkmark")
                                        } else {
                                            Text(title)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    SettingsHairline()

                    SettingsRow(
                        title: "Thinking bei Hintergrund-Jobs deaktivieren",
                        subtitle: "Schaltet den internen Denkprozess für Titel & Zusammenfassungen ab (sofern vom Server unterstützt).",
                        icon: "bolt.fill",
                        tint: DS.Accent.amber
                    ) {
                        Toggle("", isOn: $viewModel.disableThinkingForBackgroundJobs)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
            }

            settingsSection(icon: "arrow.triangle.merge", title: "Kontext-Kompaktierung (/compact)", tint: DS.Accent.blue) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    SettingsRow(
                        title: "Kompakt-Vorschlag automatisch einblenden",
                        subtitle: "Zeigt einen „Zusammenfassen“-Hinweis, sobald sich das Kontextfenster füllt.",
                        icon: "sparkles.rectangle.stack",
                        tint: DS.Accent.blue
                    ) {
                        Toggle("", isOn: $viewModel.autoCompactSuggestionsEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    if viewModel.autoCompactSuggestionsEnabled {
                        HStack(spacing: DS.Space.m) {
                            Text("Schwellwert")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(value: $viewModel.autoCompactThreshold, in: 0.5...0.9, step: 0.05)
                                .tint(DS.Ink.accent)
                            Text("\(Int(viewModel.autoCompactThreshold * 100)) %")
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                                .foregroundStyle(DS.Accent.blue)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }

                    SettingsHairline()

                    SettingsRow(
                        title: "Ziel-Länge der Zusammenfassung",
                        subtitle: "Richtwert in Tokens für die komprimierte Gesprächszusammenfassung.",
                        icon: "text.alignleft",
                        tint: DS.Accent.blue
                    ) {
                        HStack(spacing: DS.Space.s) {
                            Text("\(viewModel.compactSummaryTokens) tok")
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                                .foregroundStyle(DS.Accent.indigo)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Surface.control))
                            Stepper("", value: $viewModel.compactSummaryTokens, in: 1_000...16_000, step: 500)
                                .labelsHidden()
                        }
                    }

                    SettingsHairline()

                    SettingsRow(
                        title: "Letzte Nachrichten wörtlich behalten",
                        subtitle: "Anzahl der jüngsten Nachrichten, die unverändert erhalten bleiben.",
                        icon: "bubble.left.and.bubble.right",
                        tint: DS.Accent.blue
                    ) {
                        HStack(spacing: DS.Space.s) {
                            Text("\(viewModel.compactKeepLastMessages)")
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                                .foregroundStyle(DS.Accent.indigo)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Surface.control))
                            Stepper("", value: $viewModel.compactKeepLastMessages, in: 0...6)
                                .labelsHidden()
                        }
                    }
                }
            }

            settingsSection(icon: "play.rectangle.fill", title: "YouTube-Transkripte", tint: DS.Accent.rose) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    SettingsRow(
                        title: "Bevorzugte Untertitel-Sprache",
                        subtitle: "Wird beim Importieren von YouTube-Lernvideos vorrangig geladen.",
                        icon: "captions.bubble",
                        tint: DS.Accent.rose
                    ) {
                        SoftDropdownMenu(
                            label: viewModel.youtubeSubtitleLanguage == "de" ? "Deutsch" : (viewModel.youtubeSubtitleLanguage == "en" ? "Englisch" : "Erste verfügbare Spur"),
                            width: 185
                        ) {
                            ForEach([
                                ("de", "Deutsch"),
                                ("en", "Englisch"),
                                ("", "Erste verfügbare Spur")
                            ], id: \.0) { tag, title in
                                Button {
                                    viewModel.youtubeSubtitleLanguage = tag
                                } label: {
                                    if viewModel.youtubeSubtitleLanguage == tag {
                                        Label(title, systemImage: "checkmark")
                                    } else {
                                        Text(title)
                                    }
                                }
                            }
                        }
                    }

                    SettingsHairline()

                    SettingsRow(
                        title: "Max. Zeichen pro YouTube-Transkript",
                        subtitle: "Schützt das Kontextfenster bei sehr langen Vorlesungsaufzeichnungen.",
                        icon: "character.cursor.ibeam",
                        tint: DS.Accent.rose
                    ) {
                        TextField("30000", value: $viewModel.youtubeTranscriptCharLimit, format: .number)
                            .modifier(SettingsFieldStyle(monospaced: true))
                            .frame(width: 110)
                    }
                }
            }

            SettingsDisclosureSection(
                title: "Erweitert (Dokumente & Textauswahl)",
                subtitle: "Bild-Beschreibungsbudget für Dokumente und Kontextradius für „Text erklären“",
                icon: "slider.horizontal.3",
                tint: DS.Accent.amber
            ) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    SettingsRow(
                        title: "Dokument-Bild-Budget",
                        subtitle: "Maximale Anzahl von Bildern pro Dokument, die per KI-Vision beschrieben werden.",
                        icon: "photo.badge.checkmark",
                        tint: DS.Accent.amber,
                        help: "Verhindert übermäßige Vision-Aufrufe bei langen Skripten oder Präsentationen mit vielen Folien (0–50 Bilder, Standard 12)."
                    ) {
                        stepperBadge("\(viewModel.documentImageBudget) Bilder", value: $viewModel.documentImageBudget, range: 0...50, step: 2)
                    }

                    SettingsHairline()

                    SettingsRow(
                        title: "Kontextradius für „Text erklären“",
                        subtitle: "Zeichenmenge vor und nach der Textauswahl für präzise Begriffserklärungen.",
                        icon: "character.cursor.ibeam",
                        tint: DS.Accent.indigo,
                        help: "Bestimmt, wie viel Textumfeld der markierten Textstelle an das Modell für die Erklärung übergeben wird (100–1200 Zeichen, Standard 400 Zeichen)."
                    ) {
                        stepperBadge("± \(viewModel.inlineExplainRadius) Zeichen", value: $viewModel.inlineExplainRadius, range: 100...1200, step: 50)
                    }
                }
            }

            settingsSection(icon: "arrow.counterclockwise.circle.fill", title: "Standardwerte", tint: DS.Accent.rose) {
                SettingsRow(
                    title: "Standardwerte wiederherstellen",
                    subtitle: "Setzt technische Grenzwerte, Timeouts und Budgets zurück. Endpunkte, Modelle samt Sampling, Prompts, Lernstil, Darstellung, Hotkeys, Schalter und Quellen bleiben.",
                    icon: "arrow.counterclockwise",
                    tint: DS.Accent.rose
                ) {
                    Button("Zurücksetzen …") {
                        showResetConfirmation = true
                    }
                    .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.rose))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            "Standardwerte wiederherstellen?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Standardwerte wiederherstellen", role: .destructive) {
                viewModel.resetToDefaults()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Zurückgesetzt werden nur technische Grenzwerte, Timeouts und Budgets (Tools, Recherche, Lernen, Dokumente). Unverändert bleiben Endpunkte, Profile und Modelle samt Sampling-Werten, API-Keys, eigene Prompts, Lernstil, Darstellung, Hotkeys, Ein/Aus-Schalter, Tool-Auswahl, Recherche-Quellen, Domainlisten und Kontakt-E-Mail.")
        }
    }
}
