import SwiftUI

// MARK: - SearXNG-Katalog
// Mehrere Such-Server wie bei den Endpunkten: lokal oder remote, einer ist aktiv, Anmeldung pro Server.

struct SearXNGCatalogView: View {
    @ObservedObject var viewModel: ChatViewModel

    /// Eintrag in Bearbeitung (neu oder bestehend) samt Geheimnis.
    @State private var draft: SearXNGServer?
    @State private var draftSecret = ""
    @State private var isNew = false
    @State private var pingingID: UUID?
    @State private var pingResults: [UUID: ChatViewModel.SearXNGPingResult] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(L("Such-Server (SearXNG)"))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            if viewModel.searxngServers.isEmpty {
                Text(L("Kein Such-Server eingetragen – die Websuche nutzt dann nur die übrigen Quellen."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.searxngServers) { server in
                if draft?.id == server.id {
                    editor
                } else {
                    row(server)
                }
            }
            if isNew, draft != nil {
                editor
            } else if draft == nil {
                Button {
                    draft = SearXNGServer(name: L("Neuer Server"), url: "https://", location: .remote)
                    draftSecret = ""
                    isNew = true
                } label: {
                    Label(L("Such-Server hinzufügen"), systemImage: "plus")
                }
                .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.cyan))
            }
        }
    }

    // MARK: Zeile

    private func row(_ server: SearXNGServer) -> some View {
        let isActive = server.id == viewModel.activeSearXNGServerID
        return HStack(spacing: DS.Space.s) {
            Button {
                viewModel.selectSearXNGServer(server.id)
            } label: {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isActive ? DS.Ink.accent : .secondary)
            }
            .buttonStyle(.plain)
            .help(L("Diesen Such-Server verwenden"))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.name).font(.system(size: 12.5, weight: .medium))
                    badge(server.location == .local ? L("Lokal") : L("Remote"))
                    if server.auth != .none { badge(authLabel(server.auth), icon: "lock.fill") }
                }
                Text(server.url)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let result = pingResults[server.id] {
                    Text(result.diagnostic)
                        .font(.caption2)
                        .foregroundStyle(result == .ok ? DS.Accent.emerald : DS.Accent.rose)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Space.s)
            Button {
                ping(server, headers: viewModel.searxngHeaders(for: server))
            } label: {
                if pingingID == server.id {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(L("Ping"))
                }
            }
            .buttonStyle(SoftActionButtonStyle(tint: DS.Ink.primary))
            .disabled(pingingID != nil)
            Button {
                draft = server
                draftSecret = KeychainStore.secret(account: server.keychainAccount)
                isNew = false
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(SoftActionButtonStyle(tint: DS.Ink.primary))
            .help(L("Bearbeiten"))
            .disabled(draft != nil)
        }
        .padding(.vertical, 4)
    }

    private func badge(_ text: String, icon: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 8)) }
            Text(text)
        }
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.secondary.opacity(0.14)))
        .foregroundStyle(.secondary)
    }

    private func authLabel(_ auth: SearXNGServer.Auth) -> String {
        switch auth {
        case .none: return L("Keine")
        case .bearer: return L("Bearer-Token")
        case .basic: return L("Benutzer & Passwort")
        case .header: return L("Eigener Header")
        }
    }

    // MARK: Bearbeiten

    private var editor: some View {
        let binding = Binding<SearXNGServer>(get: { draft ?? SearXNGServer(name: "", url: "", location: .local) },
                                             set: { draft = $0 })
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.m) {
                labeledField(L("Name")) {
                    TextField(L("z. B. Caddy"), text: binding.name)
                        .modifier(SettingsFieldStyle())
                }
                .frame(width: 160)
                labeledField(L("Adresse")) {
                    TextField(L("http://127.0.0.1:8082 oder https://…"), text: binding.url)
                        .modifier(SettingsFieldStyle(monospaced: true))
                }
            }
            HStack(spacing: DS.Space.m) {
                labeledField(L("Ort")) {
                    PillPicker(options: SearXNGServer.Location.allCases, selection: binding.location,
                               label: { $0 == .local ? L("Lokal") : L("Remote") }, compact: true)
                }
                labeledField(L("Anmeldung")) {
                    PillPicker(options: SearXNGServer.Auth.allCases, selection: binding.auth,
                               label: authLabel, compact: true)
                }
            }
            if binding.wrappedValue.auth != .none {
                HStack(spacing: DS.Space.m) {
                    if binding.wrappedValue.auth == .basic {
                        labeledField(L("Benutzer")) {
                            TextField("", text: binding.username).modifier(SettingsFieldStyle())
                        }
                        .frame(width: 160)
                    }
                    if binding.wrappedValue.auth == .header {
                        labeledField(L("Header-Name")) {
                            TextField(L("z. B. X-API-Key"), text: binding.headerName)
                                .modifier(SettingsFieldStyle(monospaced: true))
                        }
                        .frame(width: 160)
                    }
                    labeledField(binding.wrappedValue.auth == .basic ? L("Passwort") : L("Token")) {
                        SecureField(L("liegt im Schlüsselbund"), text: $draftSecret)
                            .modifier(SettingsFieldStyle(monospaced: true))
                    }
                }
                Text(binding.wrappedValue.auth == .bearer
                     ? L("Wird als „Authorization: Bearer …“ mitgeschickt. Das Token liegt nur im Schlüsselbund.")
                     : L("Das Geheimnis liegt nur im Schlüsselbund, nicht in den Einstellungen."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let draft, let result = pingResults[draft.id] {
                Text(result.diagnostic)
                    .font(.caption2)
                    .foregroundStyle(result == .ok ? DS.Accent.emerald : DS.Accent.rose)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DS.Space.s) {
                Button(L("Speichern")) { saveDraft() }
                    .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.brand, prominent: true))
                    .disabled(binding.wrappedValue.url.trimmingCharacters(in: .whitespaces).count < 8)
                Button(L("Abbrechen")) { draft = nil; isNew = false; draftSecret = "" }
                    .buttonStyle(SoftActionButtonStyle(tint: DS.Ink.primary))
                Button {
                    if let draft { ping(draft, headers: draft.authHeaders(secret: draftSecret)) }
                } label: {
                    if pingingID == draft?.id { ProgressView().controlSize(.mini) } else { Text(L("Ping")) }
                }
                .buttonStyle(SoftActionButtonStyle(tint: DS.Ink.primary))
                .disabled(pingingID != nil)
                Spacer()
                if !isNew, let id = draft?.id {
                    Button(L("Löschen")) {
                        viewModel.deleteSearXNGServer(id)
                        draft = nil
                        draftSecret = ""
                    }
                    .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.rose))
                }
            }
        }
        .padding(DS.Space.s)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.secondary.opacity(0.07)))
    }

    private func saveDraft() {
        guard var server = draft else { return }
        server.name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if server.name.isEmpty { server.name = "SearXNG" }
        server.url = server.url.trimmingCharacters(in: .whitespacesAndNewlines)
        viewModel.saveSearXNGServer(server, secret: server.auth == .none ? "" : draftSecret)
        viewModel.saveSettings()
        draft = nil
        isNew = false
        draftSecret = ""
    }

    private func ping(_ server: SearXNGServer, headers: [String: String]) {
        pingingID = server.id
        pingResults[server.id] = nil
        Task {
            let result = await viewModel.testSearxngConnection(baseURL: server.url, headers: headers)
            pingResults[server.id] = result
            pingingID = nil
        }
    }
}
