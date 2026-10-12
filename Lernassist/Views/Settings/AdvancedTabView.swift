import SwiftUI

// MARK: - AdvancedTabView

struct AdvancedTabView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        // SettingsView stellt bereits die scrollbare Content-Fläche bereit. Ein geschachteltes
        // AppKit-Formular verliert unter macOS 26 beim Tabwechsel gelegentlich seinen Layout-Host:
        // Die Accessibility-Elemente existieren dann noch, die Sheet-Fläche wird aber leer oder
        // verschoben und wirkt wie ein Deadlock. Deshalb nur normale SwiftUI-Stacks verwenden.
        VStack(alignment: .leading, spacing: 20) {
            settingsSection(icon: "lock.shield", title: "Berechtigungen") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Berechtigungs-Assistent")
                            .font(.callout.weight(.medium))
                        Text("Öffnet das Ersteinrichtungs-Fenster mit den benötigten Berechtigungen (Zugriffs-Hilfen für „Auswahl erklären“, Bildschirmaufnahme für Screenshots) inkl. Live-Status und Anforderungs-Buttons.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Öffnen") {
                        NotificationCenter.default.post(name: .showPermissionOnboarding, object: nil)
                    }
                    .settingHelp("Zeigt das Berechtigungs-Fenster auch nach dem Erststart erneut – nützlich nach Updates oder wenn ein Hotkey still nichts tut.")
                }
            }

            settingsSection(icon: "gearshape.2", title: "Hintergrundprozesse") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("LernAssist kann Aufgaben im Hintergrund erledigen, wenn du den Chat gerade nicht nutzt, um den Lesefluss nicht zu stören.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Auto-Labeling aktivieren", isOn: $viewModel.autoLabelingEnabled)
                        .settingHelp("Erstellt nach der ersten Antwort automatisch einen passenden Titel für den Chat.")

                    Toggle("Bild-zu-Text Konvertierung", isOn: $viewModel.autoImageToTextEnabled)
                        .settingHelp("Wandelt hochgeladene Screenshots im Hintergrund in Textbeschreibungen um, um den Arbeitsspeicher (KV-Cache) des Modells zu schonen.")

                    Toggle("Bilder aus Dokumenten prozessieren", isOn: $viewModel.extractImagesFromPDF)
                        .settingHelp("Sendet jede PDF-Seite bzw. jedes eingebettete Bild aus Word-/PowerPoint-Dokumenten an das Vision-Modell, um Bilder und Diagramme zu beschreiben (Achtung: Kann viele Token verbrauchen).")

                    if viewModel.extractImagesFromPDF {
                        Picker("Detailgrad der Bildextraktion", selection: $viewModel.imageExtractionDetail) {
                            Text("Kurz (Ressourcenschonend)").tag("Kurz")
                            Text("Normal").tag("Normal")
                            Text("Detailliert (Kostet mehr Tokens)").tag("Detailliert")
                        }
                        .pickerStyle(.menu)
                        .settingHelp("Bestimmt, wie detailliert das Vision-Modell eingebettete Bilder aus PDFs/Word/PowerPoint beschreiben soll.")
                    }

                    Toggle("Thinking bei Hintergrund-Jobs deaktivieren (experimentell)", isOn: $viewModel.disableThinkingForBackgroundJobs)
                        .settingHelp("Best-effort: versucht, den internen Denkprozess von Reasoning-Modellen bei Titel-Generierung, Bild-Beschreibung und Zusammenfassungen abzuschalten. Bei LM Studio + Qwen3.5/3.6 kann dies serverseitig ignoriert werden.")
                }
            }

            settingsSection(icon: "text.line.first.and.arrowtriangle.forward", title: "Chat-Kontext") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Kompakt-Vorschlag zeigen", isOn: $viewModel.autoCompactSuggestionsEnabled)
                        .settingHelp("Zeigt in der Chat-Leiste einen „Zusammenfassen“-Chip, sobald der Chat das Kontextfenster zu einem großen Teil füllt.")

                    if viewModel.autoCompactSuggestionsEnabled {
                        HStack {
                            Text("Schwellwert")
                            Spacer()
                            Text("\(Int(viewModel.autoCompactThreshold * 100)) %")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $viewModel.autoCompactThreshold, in: 0.5...0.9, step: 0.05)
                            .settingHelp("Ab welchem geschätzten Kontext-Füllstand der Vorschlag erscheint.")
                    }

                    Stepper(value: $viewModel.compactSummaryTokens, in: 1_000...16_000, step: 500) {
                        HStack {
                            Text("Länge der Zusammenfassung")
                            Spacer()
                            Text("\(viewModel.compactSummaryTokens) Tokens")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .settingHelp("Richtwert für die Länge der Zusammenfassung bei „Zusammenfassen“ bzw. /compact – als Anweisung an das Modell, keine harte Grenze (nichts wird abgeschnitten). Länger = mehr Details bleiben erhalten.")

                    Stepper(value: $viewModel.compactKeepLastMessages, in: 0...6) {
                        HStack {
                            Text("Letzte Nachrichten wörtlich übernehmen")
                            Spacer()
                            Text("\(viewModel.compactKeepLastMessages)")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .settingHelp("So viele der letzten Nachrichten werden unverändert hinter die Zusammenfassung gehängt, damit das Modell weiß, worum es gerade ging.")
                }
            }

            settingsSection(icon: "play.rectangle", title: "YouTube-Import") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Bevorzugte Untertitel-Sprache", selection: $viewModel.youtubeSubtitleLanguage) {
                        Text("Deutsch").tag("de")
                        Text("Englisch").tag("en")
                        Text("Erste verfügbare Spur").tag("")
                    }
                    .pickerStyle(.menu)
                    .settingHelp("Welche Untertitel-Spur beim Importieren eines YouTube-Videos bevorzugt wird.")

                    HStack {
                        Text("Max. Zeichen pro Transkript")
                        Spacer()
                        TextField("30000", value: $viewModel.youtubeTranscriptCharLimit, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .settingHelp("Längere Transkripte werden auf diesen Wert gekürzt, damit ein einzelnes Video nicht das komplette Kontextfenster füllt.")
                    }
                }
            }

            settingsSection(icon: "arrow.triangle.2.circlepath", title: "Tool-Runden") {
                VStack(alignment: .leading, spacing: 8) {
                    Stepper(value: $viewModel.maxToolRounds, in: 1...12) {
                        HStack {
                            Text("Maximale aufeinanderfolgende Tool-Runden")
                            Spacer()
                            Text("\(viewModel.maxToolRounds)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .settingHelp("Bestimmt, wie oft das Modell innerhalb eines Turns Tools iterativ aufrufen darf. Standard: 8. Ein niedrigerer Wert begrenzt Latenz; ein höherer Wert gibt Python-/Recherche-Korrekturen mehr Raum.")

                    Text("Der Wert gilt pro Nutzer-Turn und verhindert Endlosschleifen aus Tool-Aufrufen. Nach dem Limit erhält das Modell bzw. der Nutzer ein sichtbares Ergebnis.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
