import SwiftUI

// MARK: - ModelTabView
// Modellname + Generierungs-Parameter für das aktuell aktive Endpunkt-Profil.

struct ModelTabView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var availableModels: [(id: String, contextWindow: Int?)] = []
    @State private var isLoadingModels = false
    @State private var loadError: String?

    private var activeIndex: Int? {
        viewModel.profiles.firstIndex(where: { $0.id == viewModel.activeProfileID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let idx = activeIndex {
                settingsSection(icon: "cpu", title: "Modell (\(viewModel.profiles[idx].name))") {
                    VStack(alignment: .leading, spacing: 8) {
                        labeledField("Modellname") {
                            HStack {
                                TextField("local-model", text: $viewModel.profiles[idx].model)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                                Button {
                                    loadModels(for: viewModel.profiles[idx])
                                } label: {
                                    if isLoadingModels {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(isLoadingModels)
                            }
                            .settingHelp("Modell-Liste vom Server laden (GET /v1/models bzw. /api/v0/models, je nach Endpunkt-Einstellung). Kontextfenster-Größe wird seit Kurzem auch automatisch beim Start/Profilwechsel abgefragt.")
                        }
                        labeledField("Kontext-Fenster (Override)") {
                            TextField("Auto / 8192", value: $viewModel.profiles[idx].contextSizeOverride, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .settingHelp("Erzwingt ein spezifisches Kontextfenster (Token-Limit) für die UI-Anzeige.\n• Ideal: Leer lassen (Auto)\n• Wenn voll: Trage hier die exakte Größe (z.B. 8192 oder 16384) deines lokalen Modells ein.")
                        }
                        if !availableModels.isEmpty {
                            Menu("Verfügbare Modelle (\(availableModels.count))") {
                                ForEach(availableModels, id: \.id) { m in
                                    Button(m.id) {
                                        viewModel.profiles[idx].model = m.id
                                        if let cw = m.contextWindow {
                                            viewModel.profiles[idx].contextSizeOverride = cw
                                        }
                                    }
                                }
                            }
                            .font(.caption2)
                        }
                        if let loadError {
                            Text(loadError).font(.caption2).foregroundStyle(.red)
                        }

                    }
                }

                settingsSection(icon: "hare", title: "Hintergrund-Job-Modell (optional)") {
                    labeledField("Modell für Titel / Bild-Beschreibung / Zusammenfassung") {
                        HStack {
                            TextField("Leer = Chat-Modell verwenden", text: $viewModel.profiles[idx].backgroundJobModel)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            if !availableModels.isEmpty {
                                Menu {
                                    Button("Chat-Modell verwenden (Standard)") {
                                        viewModel.profiles[idx].backgroundJobModel = ""
                                    }
                                    Divider()
                                    ForEach(availableModels, id: \.id) { m in
                                        Button(m.id) {
                                            viewModel.profiles[idx].backgroundJobModel = m.id
                                        }
                                    }
                                } label: {
                                    Image(systemName: "chevron.down.circle")
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden) // sonst überlagert macOS' eigener Pfeil das Icon
                                .frame(width: 22)
                            }
                            Button {
                                loadModels(for: viewModel.profiles[idx])
                            } label: {
                                if isLoadingModels {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoadingModels)
                        }
                        .settingHelp("Optional ein kleineres/schnelleres Modell NUR für Titel-Generierung, Bild-Beschreibung und Zusammenfassungen, um Zeit (und ggf. RAM ggü. dem großen Chat-Modell, da der Server bei Bedarf zwischen geladenen Modellen wechselt) zu sparen. Leer lassen, um immer das Chat-Modell zu nutzen. Quiz und Karteikarten nutzen bewusst weiterhin immer das volle Chat-Modell – dort zählt die inhaltliche Qualität mehr als Geschwindigkeit. Liste über \"Modelle laden\" oben befüllen.")
                    }
                }

                // LM Studio-spezifische Felder: nur bei lokalem LM Studio-Endpunkt
                if viewModel.profiles[idx].provider == .lmStudioNative ||
                   (viewModel.profiles[idx].provider == .openAICompatible &&
                    (viewModel.profiles[idx].baseURL.contains("localhost") || viewModel.profiles[idx].baseURL.contains("127.0.0.1"))) {
                    settingsSection(icon: "arrow.up.arrow.down.circle", title: "LM Studio Automatisches Laden/Entladen") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Wenn ein Modell nicht geladen ist, lädt LernAssist es automatisch über die LM Studio API.\n• Haupt-Modell: bleibt geladen, solange du dieses Profil/Modell aktiv nutzt (kein Idle-Entladen – das würde sonst zwischen zwei Nachrichten den Server-Cache verwerfen und die nächste Antwort verlangsamen). Wird erst beim Wechsel auf ein anderes Modell/Profil freigegeben.\n• Hintergrund-Modell: wird nur für die Dauer eines einzelnen Hintergrund-Jobs geladen und nach 3 Sekunden Leerlauf automatisch wieder entladen.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            labeledField("Modell-ID (Haupt-Modell)") {
                                HStack {
                                    TextField("z.B. bartowski/Qwen2.5-7B-Instruct-GGUF (Leer = Modellname oben)", text: $viewModel.profiles[idx].lmStudioModelId)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(.caption, design: .monospaced))
                                    if !availableModels.isEmpty {
                                        Menu {
                                            Button("Automatisch (aus Modellname-Feld)") {
                                                viewModel.profiles[idx].lmStudioModelId = ""
                                            }
                                            Divider()
                                            ForEach(availableModels, id: \.id) { m in
                                                Button(m.id) {
                                                    viewModel.profiles[idx].lmStudioModelId = m.id
                                                }
                                            }
                                        } label: {
                                            Image(systemName: "chevron.down.circle")
                                        }
                                        .menuStyle(.borderlessButton)
                                        .menuIndicator(.hidden)
                                        .frame(width: 22)
                                    }
                                    Button {
                                        loadModels(for: viewModel.profiles[idx])
                                    } label: {
                                        if isLoadingModels {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Image(systemName: "arrow.clockwise")
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isLoadingModels)
                                }
                                .settingHelp("Der exakte Bezeichner des Modells in LM Studio (z.B. \"bartowski/Qwen2.5-7B-Instruct-GGUF\"). Wird für den POST /api/v1/models/load-Aufruf genutzt. Leer lassen = Modellname-Feld oben wird direkt verwendet.")
                            }

                            if !viewModel.profiles[idx].backgroundJobModel.isEmpty {
                                labeledField("Modell-ID (Hintergrund-Modell)") {
                                    HStack {
                                        TextField("z.B. lmstudio-community/Qwen2.5-0.5B-Instruct (Leer = Modellname oben)", text: $viewModel.profiles[idx].backgroundJobModelLMStudioId)
                                            .textFieldStyle(.roundedBorder)
                                            .font(.system(.caption, design: .monospaced))
                                        if !availableModels.isEmpty {
                                            Menu {
                                                Button("Automatisch (aus Hintergrund-Modellname)") {
                                                    viewModel.profiles[idx].backgroundJobModelLMStudioId = ""
                                                }
                                                Divider()
                                                ForEach(availableModels, id: \.id) { m in
                                                    Button(m.id) {
                                                        viewModel.profiles[idx].backgroundJobModelLMStudioId = m.id
                                                    }
                                                }
                                            } label: {
                                                Image(systemName: "chevron.down.circle")
                                            }
                                            .menuStyle(.borderlessButton)
                                            .menuIndicator(.hidden)
                                            .frame(width: 22)
                                        }
                                        Button {
                                            loadModels(for: viewModel.profiles[idx])
                                        } label: {
                                            if isLoadingModels {
                                                ProgressView().controlSize(.small)
                                            } else {
                                                Image(systemName: "arrow.clockwise")
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(isLoadingModels)
                                    }
                                    .settingHelp("Wie oben, aber für das Hintergrundmodell. Wird beim automatischen Laden/Entladen des kleinen Hilfsmodells verwendet.")
                                }
                            }
                        }
                    }
                }

                settingsSection(
                    icon: "slider.horizontal.3",
                    title: "Generierungs-Parameter",
                    trailing: {
                        if viewModel.profiles[idx].params != .empty {
                            Button("Auf Standard zurücksetzen") {
                                viewModel.profiles[idx].params = .empty
                            }
                            .buttonStyle(.plain)
                            .font(.caption2)
                            .foregroundStyle(DS.Ink.accent)
                        } else {
                            EmptyView()
                        }
                    }
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        labeledField("Temperature", isModified: viewModel.profiles[idx].params.temperature != nil) {
                            HStack {
                                Slider(value: Binding(get: { viewModel.profiles[idx].params.temperature ?? 0.7 }, set: { viewModel.profiles[idx].params.temperature = $0 }), in: 0...2, step: 0.05)
                                Text(String(format: "%.2f", viewModel.profiles[idx].params.temperature ?? 0.7))
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 30, alignment: .trailing)
                            }
                            .settingHelp("Bestimmt die Kreativität/Zufälligkeit.\n• Ideal für Code/Logik: 0.0 - 0.3\n• Ideal für Chat/Kreativ: 0.7 - 0.9")
                        }
                        optionalDoubleField("Top P", value: $viewModel.profiles[idx].params.topP, placeholder: "z.B. 0.9")
                        optionalIntField("Top K", value: $viewModel.profiles[idx].params.topK, placeholder: "z.B. 40")
                        optionalIntField("Max Tokens", value: $viewModel.profiles[idx].params.maxTokens, placeholder: "z.B. 2048")
                        optionalDoubleField("Presence Penalty", value: $viewModel.profiles[idx].params.presencePenalty, placeholder: "z.B. 0.0")
                        optionalDoubleField("Frequency Penalty", value: $viewModel.profiles[idx].params.frequencyPenalty, placeholder: "z.B. 0.0")
                        optionalIntField("Seed", value: $viewModel.profiles[idx].params.seed, placeholder: "zufällig")
                    }
                    .settingHelp("Diese Parameter steuern die Textgenerierung. Leer lassen nutzt den Server-Default.\n• Top P: Häufig 0.9. Steuert Vokabular.\n• Top K: Häufig 40. Begrenzt Wortwahl auf Top-K.\n• Max Tokens: Ideal 2048 - 4096. Begrenzt die Antwortlänge.")
                }
            } else {
                Text("Kein aktives Profil ausgewählt – lege eines im Tab „Endpunkte“ an.")
                    .foregroundStyle(.secondary)
            }

            settingsSection(icon: "photo.on.rectangle", title: "Bilder im Verlauf") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Alle Screenshots im Chat erneut mitschicken", isOn: $viewModel.keepMultipleImagesInHistory)
                        .toggleStyle(.switch)
                        .settingHelp("Standardmäßig wird nur der neueste Screenshot mitgeschickt (spart Tokens/Kontext). Aktivieren, um Rückfragen zu älteren Screenshots im selben Chat zu ermöglichen.")
                }
            }
        }
    }

    // MARK: - Modell-Liste laden

    private func loadModels(for profile: EndpointProfile) {
        isLoadingModels = true
        loadError = nil
        Task {
            do {
                let models = try await EndpointManager.fetchModels(for: profile)
                await MainActor.run {
                    availableModels = models
                    isLoadingModels = false
                    if models.isEmpty { loadError = "Server hat keine Modelle gemeldet." }
                }
            } catch {
                await MainActor.run {
                    loadError = "Konnte Modelle nicht laden: \(error.localizedDescription)"
                    isLoadingModels = false
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
            .textFieldStyle(.roundedBorder)
            .font(.system(.caption, design: .monospaced))
        }
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
            .textFieldStyle(.roundedBorder)
            .font(.system(.caption, design: .monospaced))
        }
    }
}
