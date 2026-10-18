import SwiftUI

// MARK: - LearningModeTabView
//
// Lernmodus-Auswahl + Custom-Prompts pro Modus.
//
// WICHTIG (Re-Render-Schleifen-Fix): Der TextEditor arbeitet auf einem LOKALEN Draft
// (@State), nicht direkt auf dem @Published-Dictionary des ViewModels. Hintergrund:
// macOS-SwiftUI-TextEditoren rufen ihr Binding-SET auch während des eigenen Layouts
// auf – ein Binding, das dabei in @Published schreibt, feuert objectWillChange mitten
// im Layout → View re-rendert → TextEditor schreibt erneut → endlose Re-Render-Schleife
// (gemessen: dauerhaft 8–17 % CPU nach dem Tab-Wechsel; eskaliert beim Nutzer bis zum
// kompletten App-Freeze mit Force-Quit). Der Draft wird nur bei echter Eingabe
// (onChange, einVALUE-vergleichender Guard) zurückgeschrieben – die Schleife ist damit
// konstruktiv unmöglich.

struct LearningModeTabView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var selectedPromptStyle: LearningStyle = .beginner
    /// Lokaler Text-Puffer des Editors: Kein @Published-Feedback während des Layouts.
    @State private var promptDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            settingsSection(icon: "brain.head.profile", title: "Aktiver Lernmodus", tint: DS.Accent.amber) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    ForEach(LearningStyle.allCases, id: \.self) { style in
                        let isSelected = viewModel.learningStyle == style
                        Button {
                            viewModel.learningStyle = style
                            selectedPromptStyle = style
                        } label: {
                            HStack(spacing: DS.Space.s) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(isSelected ? DS.Ink.accent : .secondary.opacity(0.5))
                                Text(style.rawValue)
                                    .font(.system(.subheadline, design: .rounded).weight(isSelected ? .semibold : .regular))
                                    .foregroundStyle(DS.Ink.primary)
                                Spacer()
                            }
                            .padding(.horizontal, DS.Space.m)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                                    .fill(isSelected ? DS.Surface.selection : DS.Surface.control.opacity(0.55))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            settingsSection(icon: "rectangle.on.rectangle.angled", title: "Karteikarten", tint: DS.Accent.indigo) {
                SettingsRow(
                    title: "Ziel-Behaltensrate",
                    subtitle: "Wie sicher du dich bei einer Wiederholung erinnern sollst. Höher = häufiger wiederholen.",
                    icon: "target",
                    tint: DS.Accent.indigo
                ) {
                    HStack(spacing: DS.Space.s) {
                        Slider(value: $viewModel.flashcardRetention, in: 0.80...0.97, step: 0.01)
                            .frame(width: 140)
                        Text("\(Int((viewModel.flashcardRetention * 100).rounded())) %")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .frame(width: 40, alignment: .trailing)
                    }
                    .settingHelp("Wiederholungsplanung nach FSRS-5 (wie Anki). 90 % ist der empfohlene Standard; 85 % spart Zeit, 95 % verdoppelt etwa die Wiederholungen.")
                }
            }

            settingsSection(icon: "dial.medium", title: "Schwierigkeit", tint: DS.Accent.rose) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    SettingsRow(
                        title: "Abfragen im Chat",
                        subtitle: viewModel.quizDifficulty.quizGuidance,
                        icon: "questionmark.bubble",
                        tint: DS.Accent.rose,
                        help: "Gilt für Quizkarten im Chat („teste mich“, /quiz). Mit „/quiz 10 schwer Niere“ lässt sich die Stufe für ein einzelnes Quiz überschreiben."
                    ) {
                        difficultyMenu(selection: $viewModel.quizDifficulty)
                    }

                    SettingsHairline()

                    SettingsRow(
                        title: "Karteikarten",
                        subtitle: viewModel.flashcardDifficulty.cardGuidance,
                        icon: "rectangle.on.rectangle.angled",
                        tint: DS.Accent.indigo,
                        help: "Gilt für neu erzeugte Karteikarten („Als Karte merken“ und „Karten erzeugen“). Bestehende Karten bleiben unverändert."
                    ) {
                        difficultyMenu(selection: $viewModel.flashcardDifficulty)
                    }
                }
            }

            SettingsDisclosureSection(
                title: "Erweitert (Karteikarten)",
                subtitle: "Wiederholungsintervalle nach Fehlschlägen und Karten-Extraktion",
                icon: "slider.horizontal.3",
                tint: DS.Accent.indigo
            ) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    SettingsRow(
                        title: "Wiederholung nach „Nochmal“",
                        subtitle: "Zeitabstand, nach dem eine vergessene Karteikarte erneut abgefragt wird.",
                        icon: "arrow.uturn.backward.circle",
                        tint: DS.Accent.rose,
                        help: "Pause bis zur erneuten Abfrage einer vergessenen Karte in derselben Sitzung (Lapse, 1–60 min, Standard 10 min)."
                    ) {
                        stepperBadge("\(viewModel.flashcardAgainDelayMinutes) min", value: $viewModel.flashcardAgainDelayMinutes, range: 1...60, step: 1)
                    }

                    SettingsHairline()

                    SettingsRow(
                        title: "Karten pro Antwort („Als Karte merken“)",
                        subtitle: "Wie viele Karten das Modell aus einer Erklärung extrahiert.",
                        icon: "rectangle.stack.badge.plus",
                        tint: DS.Accent.indigo,
                        help: "Obergrenze für generierte Karten bei der Aktion „Als Karte merken“ (1–5 Karten, Standard 3)."
                    ) {
                        stepperBadge("\(viewModel.flashcardCardsPerResponse)", value: $viewModel.flashcardCardsPerResponse, range: 1...5, step: 1)
                    }
                }
            }

            settingsSection(icon: "text.bubble.fill", title: "System-Prompts anpassen", tint: DS.Accent.indigo) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    SettingsRow(
                        title: "Lernmodus-Prompt bearbeiten",
                        subtitle: "Wähle den Modus aus, dessen Instruktion unten angepasst werden soll.",
                        icon: selectedPromptStyle.symbol,
                        tint: DS.Accent.indigo
                    ) {
                        SoftDropdownMenu(
                            label: selectedPromptStyle.rawValue,
                            icon: selectedPromptStyle.symbol,
                            iconTint: DS.Accent.indigo,
                            width: 240
                        ) {
                            ForEach(LearningStyle.allCases, id: \.self) { style in
                                Button {
                                    selectedPromptStyle = style
                                } label: {
                                    if selectedPromptStyle == style {
                                        Label(style.rawValue, systemImage: "checkmark")
                                    } else {
                                        Label(style.rawValue, systemImage: style.symbol)
                                    }
                                }
                            }
                        }
                        .settingHelp("Bearbeite die Prompts für jeden Lernmodus. Leer lassen = Werkseinstellung.")
                    }

                    TextEditor(text: $promptDraft)
                        .font(.system(.caption, design: .default))
                        .scrollContentBackground(.hidden)
                        .frame(height: 155)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                                .fill(DS.Surface.control)
                        )

                    HStack {
                        if isCustom {
                            Label("Eigener System-Prompt aktiv", systemImage: "pencil.circle.fill")
                                .font(.caption)
                                .foregroundStyle(DS.Accent.indigo)
                        } else {
                            Label("Werkseinstellung aktiv", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(DS.Accent.emerald)
                        }
                        Spacer()
                        if isCustom {
                            Button("Auf Standard zurücksetzen") {
                                viewModel.customPrompts.removeValue(forKey: selectedPromptStyle.rawValue)
                                promptDraft = selectedPromptStyle.defaultPrompt
                            }
                            .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.rose))
                        }
                    }
                }
            }
        }
        .onAppear {
            selectedPromptStyle = viewModel.learningStyle
            promptDraft = currentStoredPrompt
        }
        // Modus-Wechsel im Editor: Draft auf den (Custom- oder Werk-)Prompt des Modus umstellen.
        .onChange(of: selectedPromptStyle) { _, _ in
            promptDraft = currentStoredPrompt
        }
        // Echte Eingabe: Draft zurückschreiben – NUR wenn er sich inhaltlich vom gespeicherten
        // Zustand unterscheidet (Guard verhindert auch hier jedes überflüssige @Published-Feuern).
        .onChange(of: promptDraft) { _, draft in
            guard draft != currentStoredPrompt else { return }
            viewModel.customPrompts[selectedPromptStyle.rawValue] = draft
        }
    }

    /// Der aktuell GESPEICHERTE Prompt des gewählten Modus (Custom falls gesetzt, sonst Werk).
    private var currentStoredPrompt: String {
        viewModel.customPrompts[selectedPromptStyle.rawValue] ?? selectedPromptStyle.defaultPrompt
    }

    private var isCustom: Bool {
        !(viewModel.customPrompts[selectedPromptStyle.rawValue] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private extension LearningModeTabView {
    func difficultyMenu(selection: Binding<StudyDifficulty>) -> some View {
        SoftDropdownMenu(label: selection.wrappedValue.label, icon: "dial.medium", iconTint: DS.Accent.rose, width: 150) {
            ForEach(StudyDifficulty.allCases) { level in
                Button {
                    selection.wrappedValue = level
                } label: {
                    if selection.wrappedValue == level {
                        Label(level.label, systemImage: "checkmark")
                    } else {
                        Text(level.label)
                    }
                }
            }
        }
    }
}
