import SwiftUI

// MARK: - ModelTabView
// Modellname + Generierungs-Parameter für das aktuell aktive Endpunkt-Profil.

struct ModelTabView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var isLoadingModels = false
    @State private var loadError: String?

    private var activeIndex: Int? {
        viewModel.profiles.firstIndex(where: { $0.id == viewModel.activeProfileID })
    }

    private var cachedModels: [(id: String, contextWindow: Int?)] {
        guard let idx = activeIndex else { return [] }
        return viewModel.cachedModelsByProfile[viewModel.profiles[idx].id] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            if let idx = activeIndex {
                let profile = viewModel.profiles[idx]

                settingsSection(
                    icon: "cpu.fill",
                    title: "Haupt-Modell (\(profile.name))",
                    tint: DS.Accent.indigo,
                    trailing: {
                        Button {
                            loadModels(for: profile)
                        } label: {
                            HStack(spacing: 4) {
                                if isLoadingModels {
                                    ProgressView().controlSize(.mini).scaleEffect(0.75)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                Text("Modelle abrufen")
                            }
                        }
                        .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.indigo))
                        .disabled(isLoadingModels)
                    }
                ) {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        HStack(alignment: .top, spacing: DS.Space.m) {
                            labeledField("Aktives Chat-Modell") {
                                modelInputWithDropdown(
                                    text: $viewModel.profiles[idx].model,
                                    placeholder: "local-model",
                                    models: cachedModels,
                                    onPick: { m in
                                        viewModel.profiles[idx].model = m.id
                                        if let cw = m.contextWindow {
                                            viewModel.profiles[idx].contextSizeOverride = cw
                                        }
                                    }
                                )
                                .settingHelp("Modell-Liste vom Server laden (GET /v1/models bzw. /api/v0/models). Sobald ein Server gepingt wurde, steht das Ausklapp-Menü direkt bereit.")
                            }
                            .frame(maxWidth: .infinity)

                            labeledField("Kontext-Fenster (Tokens)") {
                                TextField("Auto / 32768", value: $viewModel.profiles[idx].contextSizeOverride, format: .number)
                                    .modifier(SettingsFieldStyle(monospaced: true))
                                    .settingHelp("Erzwingt ein spezifisches Kontextfenster (Token-Limit) für die UI-Anzeige.\n• Ideal: Leer lassen (Auto)\n• Wenn voll: Exakte Größe (z.B. 8192 oder 32768) eintragen.")
                            }
                            .frame(width: 170)
                        }

                        if let loadError {
                            Label(loadError, systemImage: "exclamationmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(DS.Accent.rose)
                        }
                    }
                }

                settingsSection(icon: "hare.fill", title: "Hintergrund-Job-Modell (optional)", tint: DS.Accent.emerald) {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Text("Optional ein schnelles Zweitmodell für automatische Chat-Titel, Bild-Beschreibungen und Zusammenfassungen. Leer lassen, um das Haupt-Modell zu nutzen.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        labeledField("Modell für Hintergrund-Aufgaben") {
                            modelInputWithDropdown(
                                text: $viewModel.profiles[idx].backgroundJobModel,
                                placeholder: "Leer = Haupt-Modell verwenden",
                                models: cachedModels,
                                emptyOptionLabel: "Haupt-Modell verwenden (Standard)",
                                onPick: { m in
                                    viewModel.profiles[idx].backgroundJobModel = m.id
                                }
                            )
                            .settingHelp("Spart Zeit bei Hintergrund-Jobs. Quiz und Karteikarten nutzen weiterhin immer das Haupt-Modell.")
                        }
                    }
                }

                // LM Studio-spezifische Felder: nur bei lokalem LM Studio-Endpunkt
                if profile.provider == .lmStudioNative ||
                   (profile.provider == .openAICompatible &&
                    (profile.baseURL.contains("localhost") || profile.baseURL.contains("127.0.0.1"))) {
                    settingsSection(icon: "arrow.up.arrow.down.circle.fill", title: "LM Studio Auto-Load / Unload", tint: DS.Accent.cyan) {
                        VStack(alignment: .leading, spacing: DS.Space.m) {
                            Text("Lädt Modelle bei Bedarf automatisch über die LM Studio API nach. Das Haupt-Modell bleibt aktiv im Speicher; ein separates Hintergrund-Modell wird nach 3 Sekunden Leerlauf wieder entladen.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            labeledField("LM Studio Modell-ID (Haupt-Modell)") {
                                modelInputWithDropdown(
                                    text: $viewModel.profiles[idx].lmStudioModelId,
                                    placeholder: "Leer = Modellname oben verwenden",
                                    models: cachedModels,
                                    emptyOptionLabel: "Automatisch (Modellname oben)",
                                    onPick: { m in
                                        viewModel.profiles[idx].lmStudioModelId = m.id
                                    }
                                )
                            }

                            if !viewModel.profiles[idx].backgroundJobModel.isEmpty {
                                labeledField("LM Studio Modell-ID (Hintergrund-Modell)") {
                                    modelInputWithDropdown(
                                        text: $viewModel.profiles[idx].backgroundJobModelLMStudioId,
                                        placeholder: "Leer = Hintergrund-Modellname oben",
                                        models: cachedModels,
                                        emptyOptionLabel: "Automatisch (Hintergrund-Modellname)",
                                        onPick: { m in
                                            viewModel.profiles[idx].backgroundJobModelLMStudioId = m.id
                                        }
                                    )
                                }
                            }
                        }
                    }
                }

                settingsSection(
                    icon: "slider.horizontal.3",
                    title: "Generierungs-Parameter",
                    tint: DS.Accent.amber,
                    trailing: {
                        if viewModel.profiles[idx].params != .empty {
                            Button("Zurücksetzen") {
                                viewModel.profiles[idx].params = .empty
                            }
                            .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.amber))
                        } else {
                            EmptyView()
                        }
                    }
                ) {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        labeledField("Temperature (Kreativität vs. Präzision)", isModified: viewModel.profiles[idx].params.temperature != nil) {
                            HStack(spacing: DS.Space.m) {
                                Slider(
                                    value: Binding(
                                        get: { viewModel.profiles[idx].params.temperature ?? 0.7 },
                                        set: { viewModel.profiles[idx].params.temperature = $0 }
                                    ),
                                    in: 0...2,
                                    step: 0.05
                                )
                                .tint(DS.Accent.indigo)

                                Text(String(format: "%.2f", viewModel.profiles[idx].params.temperature ?? 0.7))
                                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(DS.Accent.indigo)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Surface.control))
                            }
                            .settingHelp("Bestimmt die Kreativität/Zufälligkeit.\n• Ideal für Code/Logik: 0.0 - 0.3\n• Ideal für Erklärungen: 0.6 - 0.8")
                        }

                        SettingsHairline()

                        // Sauberes 2-Spalten-Raster für alle numerischen Parameter (gleiche Breite & Höhe)
                        HStack(alignment: .top, spacing: DS.Space.m) {
                            optionalDoubleField("Top P", value: $viewModel.profiles[idx].params.topP, placeholder: "Server-Standard (z.B. 0.9)")
                            optionalIntField("Top K", value: $viewModel.profiles[idx].params.topK, placeholder: "Server-Standard (z.B. 40)")
                        }

                        HStack(alignment: .top, spacing: DS.Space.m) {
                            optionalIntField("Max Tokens", value: $viewModel.profiles[idx].params.maxTokens, placeholder: "Unbegrenzt / Auto")
                            optionalIntField("Seed", value: $viewModel.profiles[idx].params.seed, placeholder: "Zufällig")
                        }

                        HStack(alignment: .top, spacing: DS.Space.m) {
                            optionalDoubleField("Presence Penalty", value: $viewModel.profiles[idx].params.presencePenalty, placeholder: "0.0")
                            optionalDoubleField("Frequency Penalty", value: $viewModel.profiles[idx].params.frequencyPenalty, placeholder: "0.0")
                        }
                    }
                    .settingHelp("Diese Parameter steuern die Textgenerierung. Leer lassen nutzt den Server-Default.")
                }
            } else {
                Text("Kein aktives Profil ausgewählt – lege eines im Tab „Endpunkte“ an.")
                    .foregroundStyle(.secondary)
            }

            settingsSection(icon: "brain.head.profile", title: "Gedankengang (Thinking)", tint: DS.Accent.indigo) {
                SettingsRow(
                    title: "Gedankengang an das Modell zurückgeben",
                    subtitle: "Preserve Thinking: Das Thinking früherer Antworten geht unverändert mit. Hilft bei Folgefragen und Tool-Runden und nutzt den Cache des Servers.",
                    icon: "arrow.uturn.backward.circle",
                    tint: DS.Accent.indigo,
                    help: "Sendet das Thinking früherer Antworten als „reasoning_content“ mit. Ob es im Verlauf bleibt, entscheidet die Chat-Vorlage des Modells (Qwen 3.6 über oMLX: ja). Modelle ohne diese Funktion ignorieren das Feld. Kostet etwas mehr Kontext; die Anzeige in der App ist davon unabhängig."
                ) {
                    Toggle("", isOn: $viewModel.preserveThinking)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            settingsSection(icon: "photo.on.rectangle.angled", title: "Multimodaler Bild-Verlauf", tint: DS.Accent.blue) {
                SettingsRow(
                    title: "Alle Screenshots im Chat erneut mitschicken",
                    subtitle: "Standardmäßig wird nur der neueste Screenshot gesendet, um Prompt-Tokens zu sparen.",
                    icon: "photo.stack",
                    tint: DS.Accent.blue
                ) {
                    Toggle("", isOn: $viewModel.keepMultipleImagesInHistory)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .settingHelp("Aktivieren, um Rückfragen zu älteren Screenshots im selben Chat zu ermöglichen.")
                }
            }

            SettingsDisclosureSection(
                title: "Erweitert (Modell & KI)",
                subtitle: "Automatisches Nachschärfen von Chat-Titeln anhand des Verlaufs",
                icon: "slider.horizontal.3",
                tint: DS.Accent.indigo
            ) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    SettingsRow(
                        title: "Chat-Titel nachschärfen",
                        subtitle: "Aktualisiert Titel und Fachgebiet automatisch, sobald mehr Kontext vorliegt.",
                        icon: "character.textbox",
                        tint: DS.Accent.indigo,
                        help: "Nach wie vielen Nutzerfragen der Chat-Titel und das Fachgebiet anhand des bisherigen Dialogs präzisiert werden (2–10, Standard 3)."
                    ) {
                        stepperBadge("nach \(viewModel.titleRefinementTurns) Fragen", value: $viewModel.titleRefinementTurns, range: 2...10, step: 1)
                    }
                }
            }
        }
        .task(id: viewModel.activeProfileID) {
            if let idx = activeIndex, cachedModels.isEmpty {
                _ = await viewModel.loadModelsForProfile(viewModel.profiles[idx])
            }
        }
    }

    // MARK: - Modell-Feld mit integriertem Dropdown

    private func modelInputWithDropdown(
        text: Binding<String>,
        placeholder: String,
        models: [(id: String, contextWindow: Int?)],
        emptyOptionLabel: String? = nil,
        onPick: @escaping ((id: String, contextWindow: Int?)) -> Void
    ) -> some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .monospaced))

            if !models.isEmpty {
                Menu {
                    if let emptyOptionLabel {
                        Button(emptyOptionLabel) {
                            text.wrappedValue = ""
                        }
                        Divider()
                    }
                    Section("Vom Server gemeldete Modelle (\(models.count))") {
                        ForEach(models, id: \.id) { m in
                            Button {
                                onPick(m)
                            } label: {
                                HStack {
                                    if text.wrappedValue == m.id {
                                        Image(systemName: "checkmark")
                                    }
                                    if let cw = m.contextWindow {
                                        Text("\(m.id)  (\(cw / 1024)k ctx)")
                                    } else {
                                        Text(m.id)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("\(models.count)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(DS.Accent.indigo)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(DS.Accent.indigo.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Modell aus Server-Liste auswählen")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minHeight: 30)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .fill(DS.Surface.control)
        )
    }

    // MARK: - Modell-Liste laden

    private func loadModels(for profile: EndpointProfile) {
        isLoadingModels = true
        loadError = nil
        Task {
            let models = await viewModel.loadModelsForProfile(profile)
            await MainActor.run {
                isLoadingModels = false
                if models.isEmpty {
                    loadError = "Server hat keine Modelle gemeldet."
                }
            }
        }
    }

    // MARK: - Optionale Zahlenfelder (leer = nil = Server-Default)

    private func optionalDoubleField(_ label: String, value: Binding<Double?>, placeholder: String) -> some View {
        labeledField(label, isModified: value.wrappedValue != nil) {
            TextField(placeholder, text: Binding<String>(
                get: { value.wrappedValue.map { String($0) } ?? "" },
                set: { newVal in
                    let trimmed = newVal.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
                    value.wrappedValue = trimmed.isEmpty ? nil : Double(trimmed)
                }
            ))
            .modifier(SettingsFieldStyle(monospaced: true))
        }
        .frame(maxWidth: .infinity)
    }

    private func optionalIntField(_ label: String, value: Binding<Int?>, placeholder: String) -> some View {
        labeledField(label, isModified: value.wrappedValue != nil) {
            TextField(placeholder, text: Binding<String>(
                get: { value.wrappedValue.map { String($0) } ?? "" },
                set: { newVal in
                    let trimmed = newVal.trimmingCharacters(in: .whitespaces)
                    value.wrappedValue = trimmed.isEmpty ? nil : Int(trimmed)
                }
            ))
            .modifier(SettingsFieldStyle(monospaced: true))
        }
        .frame(maxWidth: .infinity)
    }
}
