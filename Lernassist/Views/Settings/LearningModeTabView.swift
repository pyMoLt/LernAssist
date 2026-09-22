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
        VStack(alignment: .leading, spacing: 20) {
            settingsSection(icon: "brain", title: "Lernmodus") {
                Picker("", selection: $viewModel.learningStyle) {
                    ForEach(LearningStyle.allCases, id: \.self) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            settingsSection(icon: "text.bubble", title: "System-Prompts anpassen") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("", selection: $selectedPromptStyle) {
                        ForEach(LearningStyle.allCases, id: \.self) { style in
                            Text(style.rawValue.components(separatedBy: " ").first ?? style.rawValue)
                                .tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .settingHelp("Bearbeite die Prompts für jeden Lernmodus. Leer lassen = Werkseinstellung.")

                    TextEditor(text: $promptDraft)
                        .font(.system(.caption, design: .default))
                        // Feste Höhe (kein Größen-Verhandelungs-Rückkopplung beim Resize)
                        .frame(height: 150)
                        .padding(6)
                        .background(Color.primary.opacity(0.04))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isCustom ? Color.blue.opacity(0.3) : Color.secondary.opacity(0.15),
                                        lineWidth: 1)
                        )

                    HStack {
                        if isCustom {
                            Label("Angepasst", systemImage: "pencil.circle.fill")
                                .font(.caption2)
                                .foregroundColor(.blue)
                        } else {
                            Label("Werkseinstellung", systemImage: "checkmark.circle")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if isCustom {
                            Button("Zurücksetzen") {
                                viewModel.customPrompts.removeValue(forKey: selectedPromptStyle.rawValue)
                                promptDraft = selectedPromptStyle.defaultPrompt
                            }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundColor(.red.opacity(0.8))
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
        .onChange(of: selectedPromptStyle) { _ in
            promptDraft = currentStoredPrompt
        }
        // Echte Eingabe: Draft zurückschreiben – NUR wenn er sich inhaltlich vom gespeicherten
        // Zustand unterscheidet (Guard verhindert auch hier jedes überflüssige @Published-Feuern).
        .onChange(of: promptDraft) { draft in
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
