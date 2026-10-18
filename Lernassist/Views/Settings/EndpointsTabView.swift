import SwiftUI

// MARK: - EndpointsTabView

struct EndpointsTabView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            settingsSection(icon: "bolt.horizontal.circle.fill", title: "Aktives Profil & Fallback", tint: DS.Accent.emerald) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    SettingsRow(
                        title: "Aktives Server-Profil",
                        subtitle: "Wird für neue Nachrichten, Screenshots und Schnell-Aktionen verwendet.",
                        icon: "checkmark.circle.fill",
                        tint: DS.Accent.emerald
                    ) {
                        SoftDropdownMenu(
                            label: viewModel.activeProfile?.name ?? "Auswählen",
                            width: 210
                        ) {
                            ForEach(viewModel.profiles) { profile in
                                Button {
                                    viewModel.activeProfileID = profile.id
                                } label: {
                                    if profile.id == viewModel.activeProfileID {
                                        Label(profile.name, systemImage: "checkmark")
                                    } else {
                                        Text(profile.name)
                                    }
                                }
                            }
                        }
                    }

                    SettingsHairline()

                    SettingsRow(
                        title: "Fallback bei Nichterreichbarkeit",
                        subtitle: "Springt einmalig ein, falls der Hauptserver beim Senden nicht antwortet.",
                        icon: "arrow.triangle.2.circlepath",
                        tint: DS.Accent.amber
                    ) {
                        SoftDropdownMenu(
                            label: viewModel.profiles.first(where: { $0.id == viewModel.fallbackProfileID })?.name ?? "Kein Fallback",
                            width: 210
                        ) {
                            Button {
                                viewModel.fallbackProfileID = nil
                            } label: {
                                if viewModel.fallbackProfileID == nil {
                                    Label("Kein Fallback", systemImage: "checkmark")
                                } else {
                                    Text("Kein Fallback")
                                }
                            }
                            Divider()
                            ForEach(viewModel.profiles) { profile in
                                Button {
                                    viewModel.fallbackProfileID = profile.id
                                } label: {
                                    if profile.id == viewModel.fallbackProfileID {
                                        Label(profile.name, systemImage: "checkmark")
                                    } else {
                                        Text(profile.name)
                                    }
                                }
                            }
                        }
                        .settingHelp("Ist das aktive Profil nicht erreichbar, wird automatisch einmalig auf dieses Profil ausgewichen – ohne Polling, nur beim tatsächlichen Senden.")
                    }

                    if viewModel.isUsingFallback {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(DS.Accent.amber)
                            Text("Aktuell im Fallback-Betrieb")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(DS.Accent.amber)
                        }
                        .padding(.horizontal, DS.Space.s)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(DS.Accent.amber.opacity(0.12)))
                    }
                }
            }

            settingsSection(
                icon: "server.rack",
                title: "Server-Profile (\(viewModel.profiles.count))",
                tint: DS.Accent.blue,
                trailing: {
                    Button(action: addProfile) {
                        HStack(spacing: 5) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .bold))
                            Text("Profil hinzufügen")
                        }
                    }
                    .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.indigo, prominent: true))
                }
            ) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    ForEach($viewModel.profiles) { $profile in
                        ProfileEditorRow(
                            profile: $profile,
                            isActive: profile.id == viewModel.activeProfileID,
                            canDelete: viewModel.profiles.count > 1,
                            cachedModels: viewModel.cachedModelsByProfile[profile.id] ?? [],
                            onSelectActive: { viewModel.activeProfileID = profile.id },
                            onDelete: { viewModel.deleteProfile(id: profile.id) },
                            onPing: { await viewModel.diagnoseConnection(profile: profile) },
                            onLoadModels: { await viewModel.loadModelsForProfile(profile) }
                        )
                    }
                }
            }
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
    let cachedModels: [(id: String, contextWindow: Int?)]
    let onSelectActive: () -> Void
    let onDelete: () -> Void
    let onPing: () async -> ConnectionDiagnosis
    let onLoadModels: () async -> [(id: String, contextWindow: Int?)]

    @State private var pingStatus: String? = nil
    @State private var pingDetail: String? = nil
    @State private var isPinging: Bool = false
    @State private var showProviderHelp: Bool = false
    @State private var showPresets: Bool = false
    @State private var isLoadingModels = false
    @State private var modelLoadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {

            // 1. Kopfzeile: Einheitliche linke Ausrichtung (feste 22pt Status-Spalte für alle Profile!)
            HStack(spacing: DS.Space.s) {
                Button(action: onSelectActive) {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isActive ? DS.Accent.emerald : .secondary.opacity(0.55))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(isActive ? "Aktives Profil" : "Als aktives Profil auswählen")

                TextField("Profilname", text: $profile.name)
                    .textFieldStyle(.plain)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(DS.Ink.primary)

                if isActive {
                    Text("AKTIV")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.Accent.emerald)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(DS.Accent.emerald.opacity(0.14)))
                }

                Spacer(minLength: DS.Space.s)

                Toggle("Remote", isOn: $profile.isRemote)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    showPresets.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Vorlagen")
                    }
                }
                .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.indigo))
                .popover(isPresented: $showPresets, arrowEdge: .bottom) {
                    PresetsPopover(profile: $profile)
                }

                // Ping-Button (lädt bei Erfolg automatisch die Modell-Liste für das Dropdown!)
                Button(action: ping) {
                    HStack(spacing: 5) {
                        if isPinging {
                            ProgressView().controlSize(.mini).scaleEffect(0.75)
                        } else {
                            Circle()
                                .fill(pingStatusColor)
                                .frame(width: 6, height: 6)
                        }
                        Text(pingStatus ?? "Ping")
                    }
                }
                .buttonStyle(SoftActionButtonStyle(tint: pingButtonTint))
                .disabled(isPinging)
                .help("Verbindung prüfen und verfügbare Modelle vom Server laden")

                if canDelete {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Surface.control))
                    }
                    .buttonStyle(.plain)
                    .help("Profil löschen")
                }
            }

            SettingsHairline()

            // 2. Zeile: Anbieter & API-Key (exakt gleiche Höhe durch labeledField auf beiden Spalten)
            HStack(alignment: .top, spacing: DS.Space.m) {
                labeledField("Anbieter / Protokoll") {
                    HStack(spacing: 6) {
                        SoftDropdownMenu(
                            label: profile.provider.displayName,
                            icon: profile.provider.systemImage,
                            iconTint: DS.Accent.indigo
                        ) {
                            ForEach(EndpointProvider.allCases, id: \.self) { p in
                                Button {
                                    let oldProvider = profile.provider
                                    profile.provider = p
                                    if oldProvider != p {
                                        let allDefaults = EndpointProvider.allCases.map {
                                            EndpointManager.normalizedBase($0.defaultBaseURL)
                                        }
                                        let normalizedCurrent = EndpointManager.normalizedBase(profile.baseURL)
                                        if allDefaults.contains(normalizedCurrent) || profile.baseURL.isEmpty {
                                            profile.baseURL = p.defaultBaseURL
                                        }
                                    }
                                } label: {
                                    if profile.provider == p {
                                        Label(p.displayName, systemImage: "checkmark")
                                    } else {
                                        Label(p.displayName, systemImage: p.systemImage)
                                    }
                                }
                            }
                        }

                        Button {
                            showProviderHelp.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 30)
                                .background(
                                    RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                                        .fill(DS.Surface.control)
                                )
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showProviderHelp, arrowEdge: .trailing) {
                            ProviderHelpPopover(provider: profile.provider)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                labeledField("API-Schlüssel (optional)") {
                    SecureField(profile.provider.apiKeyLabel, text: $profile.apiKey)
                        .modifier(SettingsFieldStyle())
                        .settingHelp("API-Key. Bei lokalen Modellen (LM Studio, Ollama, oMLX) leer lassen.")
                }
                .frame(maxWidth: .infinity)
            }

            // 3. Zeile: Server-URL & Kontextfenster (beide mit Spalten-Label auf exakt gleicher Höhe!)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: DS.Space.m) {
                    labeledField("Server-URL") {
                        TextField(profile.provider.defaultBaseURL, text: $profile.baseURL)
                            .modifier(SettingsFieldStyle(monospaced: true))
                            .settingHelp("Die Basis-URL deines Servers.\n• LM Studio: http://127.0.0.1:1234\n• Ollama: http://localhost:11434\n• oMLX: http://127.0.0.1:8000\n• OpenAI: https://api.openai.com")
                    }
                    .frame(maxWidth: .infinity)

                    labeledField("Kontext (Tokens)") {
                        TextField("Auto", value: $profile.contextSizeOverride, format: .number)
                            .modifier(SettingsFieldStyle(monospaced: true))
                            .settingHelp("Kontextgröße (Tokens).\n• Ideal: Leer lassen (Auto)\n• Lokale Modelle: Häufig 8192–32768")
                    }
                    .frame(width: 140)
                }

                if let url = EndpointManager.chatCompletionsURL(for: profile) {
                    Text("Endpunkt: \(url.absoluteString)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            // 4. Zeile: Modell-Auswahl (mit Pfeil-Dropdown direkt im selben Feld nach Ping / Abruf!)
            labeledField("Modell") {
                HStack(spacing: DS.Space.s) {
                    // Kombiniertes Modell-Eingabefeld + Ausklapp-Menü auf exakt gleicher Höhe
                    HStack(spacing: 6) {
                        Image(systemName: "cpu")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DS.Accent.indigo)

                        TextField("Modellname", text: $profile.model)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5, design: .monospaced))

                        if !cachedModels.isEmpty {
                            Menu {
                                Section("Verfügbare Server-Modelle (\(cachedModels.count))") {
                                    ForEach(cachedModels, id: \.id) { m in
                                        Button {
                                            profile.model = m.id
                                            if let cw = m.contextWindow {
                                                profile.contextSizeOverride = cw
                                            }
                                        } label: {
                                            HStack {
                                                if profile.model == m.id {
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
                                    Text("\(cachedModels.count)")
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
                            .help("Modell direkt aus der Server-Liste auswählen")
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(minHeight: 30)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                            .fill(DS.Surface.control)
                    )

                    Button {
                        loadModels()
                    } label: {
                        HStack(spacing: 4) {
                            if isLoadingModels {
                                ProgressView().controlSize(.mini).scaleEffect(0.75)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            Text("Modelle")
                        }
                    }
                    .buttonStyle(SoftActionButtonStyle())
                    .disabled(isLoadingModels)
                    .help("Modell-Liste vom Server aktualisieren")
                }
            }

            // 5. Zeile: Denkmodus (Thinking) & Timeout (ebenfalls sauber zweispaltig auf gleicher Höhe)
            HStack(alignment: .top, spacing: DS.Space.m) {
                labeledField("Denkmodus (Reasoning / Thinking)") {
                    HStack(spacing: DS.Space.s) {
                        SoftDropdownMenu(label: profile.thinkingMode.label) {
                            ForEach(ThinkingMode.allCases, id: \.self) { mode in
                                Button {
                                    profile.thinkingMode = mode
                                } label: {
                                    if profile.thinkingMode == mode {
                                        Label(mode.label, systemImage: "checkmark")
                                    } else {
                                        Text(mode.label)
                                    }
                                }
                            }
                        }
                        .settingHelp("Denkprozess des Modells für Chat-Antworten. „An“ mit Budget ist für Erklärungen empfehlenswert; „Server-Standard“ sendet nichts.")

                        if profile.thinkingMode == .on {
                            TextField("Budget", value: $profile.thinkingBudget, format: .number)
                                .modifier(SettingsFieldStyle(monospaced: true))
                                .frame(width: 95)
                                .settingHelp("Maximale Denk-Tokens (leer = unbegrenzt). Empfehlung: 2.000–4.000.")
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                labeledField("Timeout (Sek.)") {
                    TextField(profile.isRemote ? "300" : "180", value: $profile.requestTimeout, format: .number)
                        .modifier(SettingsFieldStyle(monospaced: true))
                        .settingHelp("Sekunden ohne neue Daten, bevor eine Anfrage abbricht. Leer = Standard (lokal 180 s, remote 300 s).")
                }
                .frame(width: 140)
            }

            if let err = modelLoadError {
                Label(err, systemImage: "exclamationmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(DS.Accent.rose)
            }
            if let pingDetail {
                HStack(spacing: 6) {
                    Image(systemName: (pingStatus?.hasPrefix("OK") == true) ? "checkmark.circle.fill" : "info.circle.fill")
                        .foregroundStyle((pingStatus?.hasPrefix("OK") == true) ? DS.Accent.emerald : DS.Accent.amber)
                    Text(pingDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }
        }
        .padding(DS.Space.m)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                .fill(isActive ? DS.Accent.indigo.opacity(0.05) : DS.Surface.control.opacity(0.45))
        )
    }

    private var pingStatusColor: Color {
        guard let status = pingStatus else { return DS.Accent.emerald }
        return status.hasPrefix("OK") ? DS.Accent.emerald : DS.Accent.rose
    }

    private var pingButtonTint: Color {
        guard let status = pingStatus else { return DS.Ink.primary }
        return status.hasPrefix("OK") ? DS.Accent.emerald : DS.Accent.rose
    }

    private func loadModels() {
        isLoadingModels = true
        modelLoadError = nil
        Task {
            let models = await onLoadModels()
            await MainActor.run {
                isLoadingModels = false
                if models.isEmpty {
                    modelLoadError = "Keine Modelle vom Server gemeldet."
                }
            }
        }
    }

    private func ping() {
        isPinging = true
        pingStatus = nil
        modelLoadError = nil
        Task {
            let diagnosis = await onPing()
            await MainActor.run {
                self.isPinging = false
                self.pingStatus = diagnosis.isOK ? "OK ✓" : "Fehler"
                self.pingDetail = diagnosis.message
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
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
                    .foregroundStyle(DS.Accent.indigo)
                    .font(.title3)
                Text(provider.displayName)
                    .font(.system(.headline, design: .rounded))
            }
            SettingsHairline()
            ScrollView {
                Text(provider.helpText)
                    .font(.caption)
                    .foregroundStyle(.primary)
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
        VStack(alignment: .leading, spacing: 6) {
            Text("Schnell-Vorlagen")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            ForEach(EndpointProfile.presets, id: \.name) { preset in
                Button {
                    profile.provider = preset.provider
                    profile.baseURL = preset.baseURL
                    profile.model = preset.model
                    profile.name = preset.name
                    if preset.provider == .omlx {
                        let template = EndpointProfile.looksLikeLoopback(preset.baseURL)
                            ? EndpointProfile.omlxLocal() : EndpointProfile.omlxRemote()
                        profile.params = template.params
                        profile.isRemote = template.isRemote
                        profile.thinkingMode = template.thinkingMode
                        profile.thinkingBudget = template.thinkingBudget
                    }
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(DS.Accent.indigo.opacity(0.12))
                                .frame(width: 24, height: 24)
                            Image(systemName: preset.provider.systemImage)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(DS.Accent.indigo)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(preset.name)
                                .font(.system(.caption, design: .rounded).weight(.semibold))
                            Text(preset.baseURL)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 310)
    }
}
