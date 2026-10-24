import SwiftUI

// MARK: - AdvancedTabView

struct AdvancedTabView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var showResetConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            settingsSection(icon: "lock.shield.fill", title: L("Einrichtung & Berechtigungen"), tint: DS.Accent.emerald) {
                SettingsRow(
                    title: L("Einrichtungs-Assistent"),
                    subtitle: L("Rolle dieses Macs, Verbindung zu oMLX, Recherche und Berechtigungen in fünf Schritten."),
                    icon: "wand.and.stars",
                    tint: DS.Accent.emerald
                ) {
                    Button(L("Assistent starten")) {
                        NotificationCenter.default.post(name: .showSetupAssistant, object: nil)
                    }
                    .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.emerald, prominent: true))
                    .settingHelp(L("Führt durch die komplette Einrichtung – z. B. auf einem Gerät, das die Modelle eines Servers im Netzwerk nutzt. Bestehende Chats bleiben unberührt."))
                }

                SettingsHairline()

                SettingsRow(
                    title: L("Berechtigungs-Assistent"),
                    subtitle: L("Prüft Zugriffs-Hilfen („Auswahl erklären“) und Bildschirmaufnahme (Screenshots) mit Live-Status."),
                    icon: "checkmark.shield.fill",
                    tint: DS.Accent.emerald
                ) {
                    Button(L("Assistent öffnen")) {
                        NotificationCenter.default.post(name: .showPermissionOnboarding, object: nil)
                    }
                    .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.emerald, prominent: true))
                    .settingHelp(L("Zeigt das Berechtigungs-Fenster erneut – nützlich nach Updates oder wenn ein Hotkey still nichts tut."))
                }
            }

            settingsSection(icon: "wifi", title: L("Verbindungswächter"), tint: DS.Accent.cyan, trailing: {
                if viewModel.connectionWatchEnabled {
                    Button(L("Jetzt prüfen")) { Task { await ConnectionWatch.shared.checkNow() } }
                        .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.cyan))
                        .controlSize(.small)
                }
            }) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    SettingsRow(
                        title: L("Verbindungen im Leerlauf prüfen"),
                        subtitle: L("Etwa eine Minute nach dem Start und dann alle 5 Minuten: aktiver Endpunkt, Fallback und Such-Server. Probleme erscheinen als Hinweis im Chat."),
                        icon: "wifi.exclamationmark",
                        tint: DS.Accent.cyan
                    ) {
                        Toggle("", isOn: $viewModel.connectionWatchEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .settingHelp(L("Nicht während einer Antwort. Ein Fehler wird erst nach einer zweiten Prüfung gemeldet. Weggeklickte Hinweise kommen erst wieder, wenn die Verbindung zwischendurch funktioniert hat."))
                    }
                    if viewModel.connectionWatchEnabled {
                        SettingsHairline()
                        SettingsRow(
                            title: L("Mitteilungen von macOS"),
                            subtitle: L("Zusätzlich eine Mitteilung, wenn LernAssist gerade im Hintergrund ist."),
                            icon: "bell.badge",
                            tint: DS.Accent.cyan
                        ) {
                            Toggle("", isOn: $viewModel.connectionWatchSystemNotices)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                    }
                }
            }

            settingsSection(icon: "archivebox.fill", title: L("Chats"), tint: DS.Accent.blue) {
                SettingsRow(
                    title: L("Automatisch archivieren"),
                    subtitle: L("Chats ohne Aktivität wandern ins Archiv (Sidebar unten → Archiv) und bleiben dort lesbar."),
                    icon: "clock.arrow.circlepath",
                    tint: DS.Accent.blue
                ) {
                    Picker("", selection: $viewModel.autoArchiveDays) {
                        Text(L("nach 7 Tagen")).tag(7)
                        Text(L("nach 14 Tagen")).tag(14)
                        Text(L("nach 30 Tagen")).tag(30)
                        Text(L("nach 90 Tagen")).tag(90)
                        Text("nie").tag(0)
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .settingHelp(L("Wird beim App-Start geprüft. Karteikarten archivierter Chats bleiben in der Wiederholung."))
                }
            }

            settingsSection(icon: "gearshape.2.fill", title: L("Hintergrundprozesse"), tint: DS.Accent.indigo) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    SettingsRow(
                        title: L("Automatische Chat-Titel (Auto-Labeling)"),
                        subtitle: L("Erstellt nach der ersten Antwort im Hintergrund einen prägnanten Titel."),
                        icon: "tag.fill",
                        tint: DS.Accent.indigo
                    ) {
                        Toggle("", isOn: $viewModel.autoLabelingEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    SettingsHairline()

                    SettingsRow(
                        title: L("Bild-zu-Text-Konvertierung im Hintergrund"),
                        subtitle: L("Wandelt ältere Screenshots in Textbeschreibungen um, um KV-Cache zu sparen."),
                        icon: "text.viewfinder",
                        tint: DS.Accent.cyan
                    ) {
                        Toggle("", isOn: $viewModel.autoImageToTextEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    SettingsHairline()

                    SettingsRow(
                        title: L("Eingebettete Bilder aus Dokumenten analysieren"),
                        subtitle: L("Beschreibt Folien und Abbildungen aus PDFs/Word/PowerPoint per Vision-Modell."),
                        icon: "doc.viewfinder",
                        tint: DS.Accent.amber
                    ) {
                        Toggle("", isOn: $viewModel.extractImagesFromPDF)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    if viewModel.extractImagesFromPDF {
                        SettingsRow(
                            title: L("Detailgrad der Bildextraktion"),
                            subtitle: L("Bestimmt die Ausführlichkeit der Bildbeschreibungen."),
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
                        title: L("Thinking bei Hintergrund-Jobs deaktivieren"),
                        subtitle: L("Schaltet den internen Denkprozess für Titel & Zusammenfassungen ab (sofern vom Server unterstützt)."),
                        icon: "bolt.fill",
                        tint: DS.Accent.amber
                    ) {
                        Toggle("", isOn: $viewModel.disableThinkingForBackgroundJobs)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
            }

            settingsSection(icon: "arrow.triangle.merge", title: L("Kontext-Kompaktierung (/compact)"), tint: DS.Accent.blue) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    SettingsRow(
                        title: L("Kompakt-Vorschlag automatisch einblenden"),
                        subtitle: L("Zeigt einen „Zusammenfassen“-Hinweis, sobald sich das Kontextfenster füllt."),
                        icon: "sparkles.rectangle.stack",
                        tint: DS.Accent.blue
                    ) {
                        Toggle("", isOn: $viewModel.autoCompactSuggestionsEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    if viewModel.autoCompactSuggestionsEnabled {
                        HStack(spacing: DS.Space.m) {
                            Text(L("Schwellwert"))
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
                        title: L("Ziel-Länge der Zusammenfassung"),
                        subtitle: L("Richtwert in Tokens für die komprimierte Gesprächszusammenfassung."),
                        icon: "text.alignleft",
                        tint: DS.Accent.blue
                    ) {
                        HStack(spacing: DS.Space.s) {
                            Text(L("\(viewModel.compactSummaryTokens) tok"))
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
                        title: L("Letzte Nachrichten wörtlich behalten"),
                        subtitle: L("Anzahl der jüngsten Nachrichten, die unverändert erhalten bleiben."),
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

            settingsSection(icon: "play.rectangle.fill", title: L("YouTube-Transkripte"), tint: DS.Accent.rose) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    SettingsRow(
                        title: L("Bevorzugte Untertitel-Sprache"),
                        subtitle: L("Wird beim Importieren von YouTube-Lernvideos vorrangig geladen."),
                        icon: "captions.bubble",
                        tint: DS.Accent.rose
                    ) {
                        SoftDropdownMenu(
                            label: viewModel.youtubeSubtitleLanguage == "de" ? L("Deutsch") : (viewModel.youtubeSubtitleLanguage == "en" ? L("Englisch") : L("Erste verfügbare Spur")),
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
                        title: L("Max. Zeichen pro YouTube-Transkript"),
                        subtitle: L("Schützt das Kontextfenster bei sehr langen Vorlesungsaufzeichnungen."),
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
                title: L("Erweitert (Dokumente & Textauswahl)"),
                subtitle: L("Bild-Beschreibungsbudget für Dokumente und Kontextradius für „Text erklären“"),
                icon: "slider.horizontal.3",
                tint: DS.Accent.amber
            ) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    SettingsRow(
                        title: L("Dokument-Bild-Budget"),
                        subtitle: L("Maximale Anzahl von Bildern pro Dokument, die per KI-Vision beschrieben werden."),
                        icon: "photo.badge.checkmark",
                        tint: DS.Accent.amber,
                        help: L("Verhindert übermäßige Vision-Aufrufe bei langen Skripten oder Präsentationen mit vielen Folien (0–50 Bilder, Standard 12).")
                    ) {
                        stepperBadge(L("\(viewModel.documentImageBudget) Bilder"), value: $viewModel.documentImageBudget, range: 0...50, step: 2)
                    }

                    SettingsHairline()

                    SettingsRow(
                        title: L("Kontextradius für „Text erklären“"),
                        subtitle: L("Zeichenmenge vor und nach der Textauswahl für präzise Begriffserklärungen."),
                        icon: "character.cursor.ibeam",
                        tint: DS.Accent.indigo,
                        help: L("Bestimmt, wie viel Textumfeld der markierten Textstelle an das Modell für die Erklärung übergeben wird (100–1200 Zeichen, Standard 400 Zeichen).")
                    ) {
                        stepperBadge(L("± \(viewModel.inlineExplainRadius) Zeichen"), value: $viewModel.inlineExplainRadius, range: 100...1200, step: 50)
                    }
                }
            }

            StorageLocationsSection(viewModel: viewModel)

            settingsSection(icon: "arrow.counterclockwise.circle.fill", title: L("Standardwerte"), tint: DS.Accent.rose) {
                SettingsRow(
                    title: L("Standardwerte wiederherstellen"),
                    subtitle: L("Setzt technische Grenzwerte, Timeouts und Budgets zurück. Endpunkte, Modelle samt Sampling, Prompts, Lernstil, Darstellung, Hotkeys, Schalter und Quellen bleiben."),
                    icon: "arrow.counterclockwise",
                    tint: DS.Accent.rose
                ) {
                    Button(L("Zurücksetzen …")) {
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
            Button(L("Standardwerte wiederherstellen"), role: .destructive) {
                viewModel.resetToDefaults()
            }
            Button(L("Abbrechen"), role: .cancel) {}
        } message: {
            Text(L("Zurückgesetzt werden nur technische Grenzwerte, Timeouts und Budgets (Tools, Recherche, Lernen, Dokumente). Unverändert bleiben Endpunkte, Profile und Modelle samt Sampling-Werten, API-Keys, eigene Prompts, Lernstil, Darstellung, Hotkeys, Ein/Aus-Schalter, Tool-Auswahl, Recherche-Quellen, Domainlisten und Kontakt-E-Mail."))
        }
    }
}
