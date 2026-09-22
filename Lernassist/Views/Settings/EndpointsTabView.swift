import SwiftUI

// MARK: - EndpointsTabView

struct EndpointsTabView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsSection(icon: "checkmark.circle", title: "Aktives Profil") {
                Picker("", selection: activeProfileBinding) {
                    ForEach(viewModel.profiles) { profile in
                        Text(profile.name).tag(profile.id as UUID?)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            settingsSection(icon: "arrow.triangle.2.circlepath", title: "Fallback bei Nichterreichbarkeit") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: fallbackProfileBinding) {
                        Text("Kein Fallback").tag(nil as UUID?)
                        ForEach(viewModel.profiles) { profile in
                            Text(profile.name).tag(profile.id as UUID?)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .settingHelp("Ist das aktive Profil nicht erreichbar, wird automatisch einmalig auf dieses Profil ausgewichen – ohne Polling, nur beim tatsächlichen Senden.")
                    if viewModel.isUsingFallback {
                        Label("Aktuell im Fallback-Betrieb", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
            }

            settingsSection(icon: "list.bullet", title: "Profile verwalten") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach($viewModel.profiles) { $profile in
                        ProfileEditorRow(
                            profile: $profile,
                            isActive: profile.id == viewModel.activeProfileID,
                            canDelete: viewModel.profiles.count > 1,
                            onDelete: { viewModel.deleteProfile(id: profile.id) },
                            onPing: { await viewModel.testConnection(profile: profile) }
                        )
                        if profile.id != viewModel.profiles.last?.id { Divider() }
                    }
                }
            }

            Button(action: addProfile) {
                Label("Profil hinzufügen", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundColor(.blue)
        }
    }

    private var activeProfileBinding: Binding<UUID?> {
        Binding(get: { viewModel.activeProfileID }, set: { viewModel.activeProfileID = $0 })
    }

    private var fallbackProfileBinding: Binding<UUID?> {
        Binding(get: { viewModel.fallbackProfileID }, set: { viewModel.fallbackProfileID = $0 })
    }

    private func addProfile() {
        let new = EndpointProfile(name: "Neues Profil", baseURL: "http://127.0.0.1:1234",
                                  model: "local-model", isRemote: false)
        viewModel.addProfile(new, makeActive: false)
    }
}

// MARK: - ProfileEditorRow

private struct ProfileEditorRow: View {
    @Binding var profile: EndpointProfile
    let isActive: Bool
    let canDelete: Bool
    let onDelete: () -> Void
    let onPing: () async -> Bool

    @State private var pingStatus: String? = nil
    @State private var isPinging: Bool = false
    @State private var showProviderHelp: Bool = false
    @State private var showPresets: Bool = false
    @State private var availableModels: [(id: String, contextWindow: Int?)] = []
    @State private var isLoadingModels = false
    @State private var modelLoadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            // Zeile 1: Name + Remote + Löschen
            HStack {
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                }
                TextField("Name", text: $profile.name)
                    .textFieldStyle(.plain)
                    .font(.caption.bold())
                Spacer()
                Toggle("Remote", isOn: $profile.isRemote)
                    .toggleStyle(.checkbox)
                    .font(.caption2)
                if canDelete {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Profil löschen")
                }
            }

            // Zeile 2: Provider-Picker + Fragezeichen + Presets
            HStack(spacing: 6) {
                Image(systemName: profile.provider.systemImage)
                    .font(.caption2)
                    .foregroundColor(.accentColor)
                    .frame(width: 14)

                Picker("", selection: $profile.provider) {
                    ForEach(EndpointProvider.allCases, id: \.self) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .font(.caption2)
                .onChange(of: profile.provider) { newProvider in
                    // Auto-URL wenn die aktuelle URL noch ein bekannter Default ist
                    let allDefaults = EndpointProvider.allCases.map {
                        EndpointManager.normalizedBase($0.defaultBaseURL)
                    }
                    let normalizedCurrent = EndpointManager.normalizedBase(profile.baseURL)
                    if allDefaults.contains(normalizedCurrent) || profile.baseURL.isEmpty {
                        profile.baseURL = newProvider.defaultBaseURL
                    }
                }

                // Fragezeichen: erklärt den ausgewählten Provider
                Button {
                    showProviderHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showProviderHelp, arrowEdge: .trailing) {
                    ProviderHelpPopover(provider: profile.provider)
                }

                Spacer()

                // Preset-Schnellauswahl
                Button {
                    showPresets.toggle()
                } label: {
                    Label("Preset", systemImage: "star.circle")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .popover(isPresented: $showPresets, arrowEdge: .bottom) {
                    PresetsPopover(profile: $profile)
                }
            }

            // Zeile 3: URL + Kontext-Größe
            // War vorher zweimal hintereinander gerendert (zwei TextFields auf dieselben
            // $profile.baseURL/$profile.contextSizeOverride-Bindings) – sichtbare Duplikat-Felder
            // in der GUI. Die Hilfetexte des zweiten (redundanten) Blocks sind hier mit übernommen.
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    TextField(profile.provider.defaultBaseURL, text: $profile.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .settingHelp("Die Basis-URL deines Servers.\n• LM Studio: http://127.0.0.1:1234\n• Ollama: http://localhost:11434\n• OMLX: http://127.0.0.1:8072/v1\n• OpenAI: https://api.openai.com")
                    // Auflösungsvorschau: zeigt den tatsächlichen Endpoint-Pfad
                    if let url = EndpointManager.chatCompletionsURL(for: profile) {
                        Text("→ \(url.absoluteString)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Kontext")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    TextField("auto", value: $profile.contextSizeOverride, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .frame(width: 70)
                        .settingHelp("Kontextgröße (Tokens).\n• Ideal: Leer lassen (Auto)\n• Lokale Llama3: Häufig 8192")
                }
            }

            SecureField(profile.provider.apiKeyLabel, text: $profile.apiKey)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .settingHelp("API-Key. Bei lokalen Modellen (LM Studio, Ollama) meist komplett leer lassen.")

            HStack(spacing: 4) {
                TextField("Modellname", text: $profile.model)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))

                Button {
                    loadModels()
                } label: {
                    if isLoadingModels {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isLoadingModels)
                .help("Modell-Liste vom Server laden")

                if !availableModels.isEmpty {
                    Menu {
                        ForEach(availableModels, id: \.id) { m in
                            Button {
                                profile.model = m.id
                                if let cw = m.contextWindow {
                                    profile.contextSizeOverride = cw
                                }
                            } label: {
                                if let cw = m.contextWindow {
                                    Text("\(m.id) (\(cw) ctx)")
                                } else {
                                    Text(m.id)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                            .font(.caption2)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden) // sonst zeichnet macOS zusätzlich sein eigenes Pfeil-Symbol über das Icon
                    .frame(width: 22)
                }

                // Ping
                Button(action: ping) {
                    if isPinging {
                        ProgressView().controlSize(.mini).scaleEffect(0.7)
                    } else if let status = pingStatus {
                        Text(status)
                            .font(.caption2)
                            .foregroundColor(status.hasPrefix("OK") ? .green : .red)
                    } else {
                        Text("Ping")
                            .font(.caption2)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isPinging)
            }

            if let err = modelLoadError {
                Text(err).font(.caption2).foregroundColor(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private func loadModels() {
        isLoadingModels = true
        modelLoadError = nil
        Task {
            do {
                let models = try await EndpointManager.fetchModels(for: profile)
                await MainActor.run {
                    availableModels = models
                    isLoadingModels = false
                    if models.isEmpty { modelLoadError = "Server hat keine Modelle gemeldet." }
                }
            } catch {
                await MainActor.run {
                    modelLoadError = "Fehler: \(error.localizedDescription)"
                    isLoadingModels = false
                }
            }
        }
    }

    private func ping() {
        isPinging = true
        pingStatus = nil
        Task {
            let success = await onPing()
            await MainActor.run {
                self.isPinging = false
                self.pingStatus = success ? "OK ✓" : "Fehler ✗"
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if self.pingStatus != nil { self.pingStatus = nil }
                }
            }
        }
    }
}

// MARK: - Provider Help Popover

private struct ProviderHelpPopover: View {
    let provider: EndpointProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: provider.systemImage)
                    .foregroundColor(.accentColor)
                    .font(.title3)
                Text(provider.displayName)
                    .font(.headline)
            }
            Divider()
            ScrollView {
                Text(provider.helpText)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(14)
        .frame(width: 340, height: 260)
    }
}

// MARK: - Presets Popover

private struct PresetsPopover: View {
    @Binding var profile: EndpointProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Schnell-Presets")
                .font(.caption.bold())
                .foregroundColor(.secondary)
                .padding(.bottom, 2)

            ForEach(EndpointProfile.presets, id: \.name) { preset in
                Button {
                    profile.provider = preset.provider
                    profile.baseURL = preset.baseURL
                    profile.model = preset.model
                    profile.name = preset.name
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: preset.provider.systemImage)
                            .foregroundColor(.accentColor)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(preset.name)
                                .font(.caption.bold())
                            Text(preset.baseURL)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if preset.name != EndpointProfile.presets.last?.name {
                    Divider()
                }
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}
