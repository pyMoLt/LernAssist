import SwiftUI

// MARK: - ModelsTabView (Version 4.0)

/// Einstellungen pro Modell: Denken, Denkstärke, Preserve Thinking, Sampling, Kontextfenster und
/// Schalter der Chat-Vorlage. Sie hängen am Modellnamen und gelten über alle Profile und Anbieter.
struct ModelsTabView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var selectedModel: String = ""
    @State private var newKwargKey = ""
    @State private var newKwargValue = ""

    /// Alle bekannten Modelle: aus Profilen, Server-Listen und bereits gespeicherten Einstellungen.
    private var knownModels: [String] {
        var names = Set<String>()
        var result: [String] = []
        func add(_ name: String) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, names.insert(ModelSettings.key(for: trimmed)).inserted else { return }
            result.append(trimmed)
        }
        if let active = viewModel.activeProfile?.model { add(active) }
        viewModel.profiles.forEach { add($0.model); add($0.backgroundJobModel) }
        viewModel.cachedModelsByProfile.values.flatMap { $0 }.forEach { add($0.id) }
        viewModel.modelSettings.keys.forEach { add($0) }
        return result
    }

    private var key: String { ModelSettings.key(for: selectedModel) }
    private var current: ModelSettings { viewModel.modelSettings[key] ?? ModelSettings() }
    private var preset: ModelPreset? { ModelPreset.matching(selectedModel) }

    private func update(_ change: (inout ModelSettings) -> Void) {
        var entry = current
        change(&entry)
        viewModel.modelSettings[key] = entry.isEmpty ? nil : entry
    }

    private func binding<T>(_ keyPath: WritableKeyPath<ModelSettings, T>) -> Binding<T> {
        Binding(get: { current[keyPath: keyPath] }, set: { value in update { $0[keyPath: keyPath] = value } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            modelPicker
            if !selectedModel.isEmpty {
                thinkingSection
                behaviourSection
                samplingSection
                templateSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if selectedModel.isEmpty { selectedModel = viewModel.activeProfile?.model ?? knownModels.first ?? "" }
        }
    }

    // MARK: Modell

    private var modelPicker: some View {
        settingsSection(icon: "cube", title: L("Modell")) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                SettingsRow(title: L("Modell"),
                            subtitle: L("Einstellungen gelten für dieses Modell – über alle Profile und Anbieter hinweg.")) {
                    SoftDropdownMenu(label: selectedModel.isEmpty ? L("Modell wählen") : selectedModel, width: 280) {
                        ForEach(knownModels, id: \.self) { model in
                            Button {
                                selectedModel = model
                            } label: {
                                let configured = viewModel.modelSettings[ModelSettings.key(for: model)] != nil
                                if ModelSettings.key(for: model) == key {
                                    Label(model, systemImage: "checkmark")
                                } else if configured {
                                    Label(model, systemImage: "slider.horizontal.3")
                                } else {
                                    Text(model)
                                }
                            }
                        }
                    }
                }

                if let preset {
                    SettingsHairline()
                    VStack(alignment: .leading, spacing: 4) {
                        Label(L("Erkannt: \(preset.name)"), systemImage: "sparkles")
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(DS.Ink.accent)
                        Text(preset.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                SettingsHairline()
                HStack(spacing: DS.Space.s) {
                    if let preset, !preset.recommended.isEmpty {
                        Button(L("Empfohlene Werte übernehmen")) {
                            update { entry in
                                let r = preset.recommended
                                entry.temperature = r.temperature ?? entry.temperature
                                entry.topP = r.topP ?? entry.topP
                                entry.topK = r.topK ?? entry.topK
                                entry.minP = r.minP ?? entry.minP
                            }
                        }
                        .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.brand, prominent: true))
                        .help(L("Sampling-Werte, die der Hersteller für dieses Modell empfiehlt"))
                    }
                    Spacer()
                    Button(L("Zurücksetzen")) { viewModel.modelSettings[key] = nil }
                        .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.rose))
                        .disabled(current.isEmpty)
                        .help(L("Alle Einstellungen dieses Modells entfernen – dann gelten Profil und Server-Standard"))
                }
            }
        }
    }

    // MARK: Denken

    private var thinkingSection: some View {
        settingsSection(icon: "brain.head.profile", title: L("Denken")) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                SettingsRow(title: L("Denken (Thinking)"),
                            subtitle: L("„Standard“ sendet nichts – dann entscheidet der Server bzw. die Chat-Vorlage.")) {
                    PillPicker(options: [ThinkingMode.serverDefault, .on, .off],
                               selection: Binding(get: { current.thinking ?? .serverDefault },
                                                  set: { mode in update { $0.thinking = mode == .serverDefault ? nil : mode } }),
                               label: { mode in
                                   switch mode {
                                   case .serverDefault: return L("Standard")
                                   case .on: return L("An")
                                   case .off: return L("Aus")
                                   }
                               }, compact: true)
                }

                if current.thinking == .on {
                    SettingsHairline()
                    SettingsRow(title: L("Denk-Budget"), subtitle: L("Maximale Denk-Tokens (leer = unbegrenzt). Empfehlung: 2.000–4.000.")) {
                        OptionalNumberField(placeholder: L("unbegrenzt"), value: binding(\.thinkingBudget))
                    }
                }

                SettingsHairline()
                SettingsRow(title: L("Denkstärke"),
                            subtitle: preset?.effortLevels.isEmpty == false
                                ? L("„reasoning_effort“: wie gründlich das Modell nachdenkt.")
                                : L("„reasoning_effort“ – nur für Modelle, die Stufen kennen (z. B. low, medium, high). Leer = nicht senden.")) {
                    if let levels = preset?.effortLevels, !levels.isEmpty {
                        PillPicker(options: [""] + levels,
                                   selection: Binding(get: { current.reasoningEffort ?? "" },
                                                      set: { value in update { $0.reasoningEffort = value.isEmpty ? nil : value } }),
                                   label: { $0.isEmpty ? L("Standard") : $0 }, compact: true)
                    } else {
                        TextField(L("z. B. medium"), text: Binding(get: { current.reasoningEffort ?? "" },
                                                                 set: { value in update { $0.reasoningEffort = value.isEmpty ? nil : value } }))
                            .modifier(SettingsFieldStyle(monospaced: true))
                            .frame(width: 140)
                    }
                }

                SettingsHairline()
                SettingsRow(title: L("Gedankengang an das Modell zurückgeben"),
                            subtitle: L("Preserve Thinking: Das Thinking früherer Antworten geht unverändert mit. Hilft bei Folgefragen und Tool-Runden und nutzt den Cache des Servers."),
                            help: L("Sendet das Thinking früherer Antworten als „reasoning_content“ mit. Ob es im Verlauf bleibt, entscheidet die Chat-Vorlage des Modells (Qwen 3.6 über oMLX: ja). Modelle ohne diese Funktion ignorieren das Feld. Kostet etwas mehr Kontext; die Anzeige in der App ist davon unabhängig.")) {
                    Toggle("", isOn: Binding(get: { current.preserveThinking ?? true },
                                             set: { on in update { $0.preserveThinking = on ? nil : false } }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                if preset?.supportsVerification == true {
                    SettingsHairline()
                    SettingsRow(title: L("Verification-Modus"),
                                subtitle: L("Selbstprüfung im Gedankengang: Das Modell prüft zwischendurch, was belegt ist und was nicht, und korrigiert seinen Weg. Etwas längeres Denken."),
                                help: L("Sage-A1.5: chat_template_kwargs.verification = true. Die Vorlage hängt dann „Verification protocol: enabled“ an den System-Prompt.")) {
                        Toggle("", isOn: Binding(get: { current.verification ?? false },
                                                 set: { on in update { $0.verification = on ? true : nil } }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
            }
        }
    }

    // MARK: Antwort & Bilder

    private var behaviourSection: some View {
        settingsSection(icon: "waveform", title: L("Antwort & Bilder")) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                SettingsRow(title: L("Antworten streamen"),
                            subtitle: L("Text erscheint, während das Modell schreibt. Aus: Die Antwort kommt am Stück – nur nötig, wenn ein Server beim Streamen Probleme macht.")) {
                    Toggle("", isOn: Binding(get: { current.streaming ?? true },
                                             set: { on in update { $0.streaming = on ? nil : false } }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                SettingsHairline()
                SettingsRow(title: L("Bilder an das Modell senden (Vision)"),
                            subtitle: L("Aus für Modelle ohne Bildeingabe: Screenshots gehen dann als Textbeschreibung mit, sobald eine vorliegt.")) {
                    Toggle("", isOn: Binding(get: { current.vision ?? true },
                                             set: { on in update { $0.vision = on ? nil : false } }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
        }
    }

    // MARK: Sampling

    private var samplingSection: some View {
        settingsSection(icon: "dial.medium", title: L("Sampling & Kontext")) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(L("Leere Felder: Es gilt der Wert des Profils bzw. der Standard des Servers."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: DS.Space.m, verticalSpacing: DS.Space.s) {
                    GridRow {
                        numberCell("temperature", binding(\.temperature))
                        numberCell("top_p", binding(\.topP))
                        numberCell("top_k", binding(\.topK))
                    }
                    GridRow {
                        numberCell("min_p", binding(\.minP))
                        numberCell("presence_penalty", binding(\.presencePenalty))
                        numberCell("repetition_penalty", binding(\.repetitionPenalty))
                    }
                    GridRow {
                        numberCell("max_tokens", binding(\.maxTokens))
                        numberCell(L("Kontextfenster (Tokens)"), binding(\.contextWindow))
                        Color.clear.frame(height: 1)
                    }
                }
            }
        }
    }

    private func numberCell<T: LosslessStringConvertible>(_ label: String, _ value: Binding<T?>) -> some View {
        labeledField(label, isModified: value.wrappedValue != nil) {
            OptionalNumberField(placeholder: L("Profil/Server"), value: value)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Chat-Vorlage

    private var templateSection: some View {
        SettingsDisclosureSection(title: L("Erweitert (Schalter der Chat-Vorlage)"),
                                  subtitle: L("Eigene chat_template_kwargs, z. B. für neue Modelle mit Sonderschaltern"),
                                  icon: "curlybraces") {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                ForEach(current.templateKwargs.keys.sorted(), id: \.self) { name in
                    HStack {
                        Text(name).font(.system(size: 12.5, design: .monospaced))
                        Text("=").foregroundStyle(.tertiary)
                        Text(current.templateKwargs[name] ?? "").font(.system(size: 12.5, design: .monospaced))
                        Spacer()
                        Button { update { $0.templateKwargs[name] = nil } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("Schalter \(name) entfernen"))
                    }
                }
                HStack(spacing: DS.Space.s) {
                    TextField(L("Name, z. B. enable_thinking"), text: $newKwargKey)
                        .modifier(SettingsFieldStyle(monospaced: true))
                    TextField(L("Wert, z. B. true"), text: $newKwargValue)
                        .modifier(SettingsFieldStyle(monospaced: true))
                        .frame(width: 140)
                    Button(L("Hinzufügen")) {
                        let name = newKwargKey.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        update { $0.templateKwargs[name] = newKwargValue.trimmingCharacters(in: .whitespaces) }
                        newKwargKey = ""; newKwargValue = ""
                    }
                    .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.brand))
                    .disabled(newKwargKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text(L("Werte „true“/„false“ und Zahlen werden als JSON-Typen gesendet. Gelten nur für Chat-Antworten."))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Zahlenfeld mit „leer = nicht gesetzt“ (Komma oder Punkt als Dezimaltrenner).
struct OptionalNumberField<T: LosslessStringConvertible>: View {
    let placeholder: String
    @Binding var value: T?

    var body: some View {
        TextField(placeholder, text: Binding<String>(
            get: { value.map { String(describing: $0) } ?? "" },
            set: { text in
                let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
                value = trimmed.isEmpty ? nil : T(trimmed)
            }))
            .modifier(SettingsFieldStyle(monospaced: true))
            .frame(minWidth: 90)
    }
}
