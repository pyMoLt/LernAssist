import SwiftUI

// MARK: - Einrichtungs-Assistent
//
// Erster Start (oder Einstellungen → Erweitert): richtet in fünf kurzen Schritten alles ein,
// was sonst über mehrere Tabs verteilt ist – Rolle des Macs, Verbindung zu oMLX (mit Test und
// Modellwahl), Recherche (SearXNG + Websuche), Berechtigungen und Python-Status.

struct SetupAssistantView: View {
    @ObservedObject var viewModel: ChatViewModel
    var onClose: () -> Void

    enum Role: String, CaseIterable, Identifiable {
        case server, client, other
        var id: String { rawValue }
        var title: String {
            switch self {
            case .server: return L("Modelle laufen auf diesem Mac")
            case .client: return L("Remote-Endpunkt nutzen")
            case .other:  return L("Anderer Anbieter")
            }
        }
        var detail: String {
            switch self {
            case .server: return L("oMLX läuft hier lokal.")
            case .client: return L("Die Modelle laufen auf einem Server im Netzwerk, erreichbar über LAN oder ein VPN wie Tailscale.")
            case .other:  return L("LM Studio, Ollama oder ein OpenAI-kompatibler Dienst – Einrichtung später unter Einstellungen → Endpunkte.")
            }
        }
        var icon: String {
            switch self {
            case .server: return "desktopcomputer"
            case .client: return "laptopcomputer.and.arrow.down"
            case .other:  return "server.rack"
            }
        }
    }

    enum Step: Int, CaseIterable { case role, connection, research, permissions, done }

    @State private var step: Step = .role
    @State private var role: Role = .server
    @State private var host = ""
    @State private var serverURL = "http://127.0.0.1:8072"
    @State private var apiKey = ""
    @State private var model = EndpointProfile.recommendedOMLXModel
    @State private var draftProfile = EndpointProfile.omlxLocal()
    @State private var connectionResult: ConnectionDiagnosis?
    @State private var isTesting = false
    @State private var searxngURL = "http://127.0.0.1:8082"
    @State private var searchEnabled = true
    @State private var searxngOK: Bool?
    @State private var contactEmail = ""

    var body: some View {
        VStack(spacing: 0) {
            progress
            Group {
                switch step {
                case .role:        roleStep
                case .connection:  connectionStep
                case .research:    researchStep
                case .permissions: permissionsStep
                case .done:        doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, DS.Space.xl)
            .padding(.top, DS.Space.l)
            footer
        }
        .frame(width: 560, height: 520)
        .background(DS.Surface.canvas)
        .onAppear(perform: prefill)
    }

    // MARK: Schritte

    private var roleStep: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.m) {
                LernAssistBrandIcon(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Willkommen bei LernAssist")).font(.system(.title2, design: .rounded).weight(.semibold))
                    Text(L("In fünf kurzen Schritten ist alles eingerichtet.")).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, DS.Space.s)
            ForEach(Role.allCases) { item in
                Button { role = item } label: {
                    HStack(alignment: .top, spacing: DS.Space.m) {
                        Image(systemName: item.icon)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(DS.Ink.accent)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.system(.headline, design: .rounded))
                            Text(item.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: role == item ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(role == item ? DS.Ink.accent : .secondary)
                    }
                    .padding(DS.Space.m)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                        .fill(role == item ? DS.Surface.selection : DS.Surface.chip))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var connectionStep: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            stepTitle(L("Verbindung zu oMLX"), role == .client
                      ? "Hostname oder IP des Servers, auf dem oMLX läuft (z. B. ein Tailscale-Name). Dort muss oMLX Verbindungen von außen annehmen (nicht nur 127.0.0.1)."
                      : "oMLX auf diesem Gerät, Standard-Port 8072.")
            if role == .client {
                labeled("Server") {
                    TextField(L("Hostname oder IP"), text: $host).textFieldStyle(.plain).modifier(SettingsFieldStyle())
                        .onChange(of: host) { _, _ in connectionResult = nil }
                }
            } else {
                labeled("Adresse") {
                    TextField(L("http://127.0.0.1:8072"), text: $serverURL).textFieldStyle(.plain).modifier(SettingsFieldStyle())
                        .onChange(of: serverURL) { _, _ in connectionResult = nil }
                }
            }
            labeled("API-Key") {
                SecureField(role == .client ? L("Pflicht, wenn oMLX von außen erreichbar ist") : L("Optional"), text: $apiKey)
                    .textFieldStyle(.plain).modifier(SettingsFieldStyle())
            }
            HStack(spacing: DS.Space.s) {
                Button { Task { await testConnection() } } label: {
                    if isTesting { ProgressView().controlSize(.small) } else { Label(L("Verbindung testen"), systemImage: "bolt.horizontal") }
                }
                .buttonStyle(SoftActionButtonStyle(tint: DS.Ink.accent, prominent: true))
                .disabled(isTesting)
                if let result = connectionResult {
                    Label(result.message, systemImage: result.isOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(result.isOK ? DS.Accent.emerald : .orange)
                        .lineLimit(3)
                }
            }
            let models = (viewModel.cachedModelsByProfile[draftProfile.id] ?? []).map(\.id)
            if !models.isEmpty {
                labeled("Modell") {
                    Picker("", selection: $model) {
                        ForEach(Array(Set(models + [model])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
            }
        }
    }

    private var researchStep: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            stepTitle(L("Recherche"), "Die Websuche fragt SearXNG, Wikipedia und Fachdatenbanken (PubMed/Europe PMC, arXiv, Stack Exchange) und belegt Aussagen mit Quellen.")
            Toggle(L("Websuche aktivieren"), isOn: $searchEnabled).toggleStyle(.switch)
            labeled("SearXNG") {
                HStack {
                    TextField(L("http://127.0.0.1:8082"), text: $searxngURL).textFieldStyle(.plain).modifier(SettingsFieldStyle())
                    Button(L("Testen")) { Task { await testSearxng() } }.buttonStyle(SoftActionButtonStyle(tint: DS.Ink.accent))
                }
            }
            if let ok = searxngOK {
                Label(ok ? L("SearXNG antwortet.") : L("SearXNG nicht erreichbar – die Suche nutzt dann nur Wikipedia und die Fachdatenbanken."),
                      systemImage: ok ? "checkmark.circle.fill" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(ok ? DS.Accent.emerald : .secondary)
            }
            labeled("Kontakt-E-Mail") {
                TextField(L("Optional – Wikipedia & Europe PMC bitten darum"), text: $contactEmail).textFieldStyle(.plain).modifier(SettingsFieldStyle())
            }
            Text(L("Die E-Mail geht nur an Wikipedia, Europe PMC, arXiv und Stack Exchange (deren Nutzungsregeln), sonst nirgendwohin."))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            stepTitle(L("Berechtigungen"), "Bildschirmaufnahme für den Screenshot-Hotkey, Zugriffs-Hilfen für „Auswahl erklären“. Nach einem Update kann macOS erneut fragen.")
            TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                VStack(spacing: DS.Space.s) {
                    ForEach(AppPermissions.all) { PermissionRow(permission: $0) }
                }
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            stepTitle(L("Fertig"), "LernAssist ist eingerichtet.")
            summaryRow("bolt.horizontal", L("Verbindung"), role == .other ? L("Später unter Einstellungen → Endpunkte") : draftProfile.baseURL)
            summaryRow("magnifyingglass", L("Websuche"), searchEnabled ? L("an · \(searxngURL)") : "aus")
            summaryRow("camera.viewfinder", L("Screenshot"), hotkeyText)
            summaryRow("chevron.left.forwardslash.chevron.right", L("Python"), pythonText)
            Text(L("Alles lässt sich später in den Einstellungen ändern; den Assistenten gibt es unter Erweitert erneut."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, DS.Space.s)
        }
    }

    // MARK: Rahmen

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { item in
                Capsule()
                    .fill(item.rawValue <= step.rawValue ? DS.Ink.accent : DS.Surface.chipHover)
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.top, DS.Space.l)
        .accessibilityLabel(L("Schritt \(step.rawValue + 1) von \(Step.allCases.count)"))
    }

    private var footer: some View {
        HStack {
            if step != .role {
                Button(L("Zurück")) { withAnimation(.snappy) { step = previous(step) } }
                    .buttonStyle(SoftActionButtonStyle())
            }
            Spacer()
            if step == .role {
                Button(L("Später")) { onClose() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Button(step == .done ? L("Los geht’s") : L("Weiter")) { advance() }
                .buttonStyle(SoftActionButtonStyle(tint: DS.Ink.accent, prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(step == .connection && role == .client && host.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(DS.Space.l)
    }

    private func stepTitle(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(.title3, design: .rounded).weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, DS.Space.xs)
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: DS.Space.m) {
            Text(label).font(.callout).frame(width: 110, alignment: .leading)
            content()
        }
    }

    private func summaryRow(_ icon: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: icon).foregroundStyle(DS.Ink.accent).frame(width: 22)
            Text(title).font(.callout.weight(.medium)).frame(width: 100, alignment: .leading)
            Text(value).font(.callout).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private var hotkeyText: String {
        viewModel.hotkeys[.screenshot].map { "\($0.displayString) – Bereich aufnehmen und erklären lassen" } ?? "⌘⇧L"
    }

    private var pythonText: String {
        switch viewModel.pythonEnvironmentStatus {
        case .ready(let version): return L("bereit (Python \(version))")
        case .failed(let message): return L("Fehler: \(message) – Einstellungen → Tools")
        case .unknown: return L("wird geprüft …")
        default: return L("wird im Hintergrund eingerichtet (~630 MB)")
        }
    }

    // MARK: Logik

    private func prefill() {
        if let active = viewModel.activeProfile, active.provider == .omlx {
            role = active.isRemote ? .client : .server
            draftProfile = active
            model = active.model
            apiKey = active.apiKey
            if active.isRemote, let parsed = URL(string: active.baseURL)?.host { host = parsed } else { serverURL = active.baseURL }
        }
        searxngURL = viewModel.searxngURL
        searchEnabled = viewModel.searchEnabled || !viewModel.setupCompleted
        contactEmail = viewModel.research.apiContactEmail
    }

    private func previous(_ step: Step) -> Step {
        if step == .research, role == .other { return .role }
        return Step(rawValue: step.rawValue - 1) ?? .role
    }

    private func advance() {
        switch step {
        case .role:
            let trimmedHost = host.trimmingCharacters(in: .whitespaces)
            if role == .client, !trimmedHost.isEmpty, searxngURL.contains("127.0.0.1") { searxngURL = "http://\(trimmedHost):8082" }
            withAnimation(.snappy) { step = role == .other ? .research : .connection }
        case .connection:
            let trimmedHost = host.trimmingCharacters(in: .whitespaces)
            // Ohne Hostname kein sinnvoller Remote-Endpunkt.
            guard role != .client || !trimmedHost.isEmpty else { return }
            if role == .client, searxngURL.contains("127.0.0.1") { searxngURL = "http://\(trimmedHost):8082" }
            withAnimation(.snappy) { step = .research }
        case .research:
            withAnimation(.snappy) { step = .permissions }
        case .permissions:
            withAnimation(.snappy) { step = .done }
        case .done:
            apply()
            onClose()
        }
    }

    /// Profil, das aus den Eingaben entsteht (gleiche ID wie der Entwurf, damit Testergebnis und Modelle passen).
    private func buildProfile() -> EndpointProfile {
        var profile = role == .client ? EndpointProfile.omlxRemote(host: host.trimmingCharacters(in: .whitespaces)) : EndpointProfile.omlxLocal()
        if role == .server { profile.baseURL = serverURL.trimmingCharacters(in: .whitespaces) }
        profile.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.model = model
        return EndpointProfile(copying: profile, id: draftProfile.id)
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        let profile = buildProfile()
        draftProfile = profile
        connectionResult = await viewModel.diagnoseConnection(profile: profile)
        if let models = viewModel.cachedModelsByProfile[profile.id]?.map(\.id), !models.isEmpty, !models.contains(model) {
            model = models.first { $0 == EndpointProfile.recommendedOMLXModel } ?? models[0]
        }
    }

    private func testSearxng() async {
        guard var components = URLComponents(string: searxngURL.trimmingCharacters(in: .whitespaces)) else { searxngOK = false; return }
        components.path = (components.path.hasSuffix("/") ? components.path : components.path + "/") + "search"
        components.queryItems = [URLQueryItem(name: "q", value: "test"), URLQueryItem(name: "format", value: "json")]
        guard let url = components.url else { searxngOK = false; return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        let status = (try? await URLSession.shared.data(for: request)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
        searxngOK = status == 200
    }

    private func apply() {
        if role != .other {
            let profile = buildProfile()
            if let index = viewModel.profiles.firstIndex(where: { $0.id == profile.id }) {
                viewModel.profiles[index] = profile
                viewModel.activeProfileID = profile.id
                viewModel.saveSettings()
            } else if let index = viewModel.profiles.firstIndex(where: { $0.baseURL == profile.baseURL }) {
                var existing = viewModel.profiles[index]
                existing.apiKey = profile.apiKey
                existing.model = profile.model
                viewModel.profiles[index] = existing
                viewModel.activeProfileID = existing.id
                viewModel.saveSettings()
            } else {
                viewModel.addProfile(profile, makeActive: true)
            }
            viewModel.refreshContextWindowForActiveProfile()
        }
        viewModel.searxngURL = searxngURL.trimmingCharacters(in: .whitespaces)
        viewModel.searchEnabled = searchEnabled
        viewModel.research.apiContactEmail = contactEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        viewModel.setupCompleted = true
        if AppPermissions.allGranted { UserDefaults.standard.set(true, forKey: "hasCompletedPermissionOnboarding") }
        viewModel.saveSettings()
    }
}
