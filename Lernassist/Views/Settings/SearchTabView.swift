import SwiftUI

// MARK: - SearchTabView
// Websuche & Browsing (unverändert aus der ursprünglichen SettingsView übernommen).
// Wird in Phase 5 durch einen allgemeinen "Tools"-Tab mit pro-Tool-Toggles abgelöst.

struct SearchTabView: View {
    @ObservedObject var viewModel: ChatViewModel

    @State private var isPinging = false
    @State private var pingStatus: String? = nil

    /// Setzt Web-Suche UND Browsing gemeinsam (siehe ChatViewModel.setSearchAndBrowsingEnabled) und
    /// überträgt die Änderung sofort in die ToolRegistry, statt erst bei einem späteren, unabhängigen
    /// syncToolRegistry()-Aufruf (App-Neustart oder Interaktion im Tools-Tab).
    private var searchAndBrowsingBinding: Binding<Bool> {
        Binding(
            get: { viewModel.searchEnabled },
            set: { viewModel.setSearchAndBrowsingEnabled($0) }
        )
    }

    private func ping() {
        isPinging = true
        pingStatus = nil
        let url = viewModel.searxngURL
        Task {
            // Ursachengerechte Diagnose statt nacktem Fehler ✗: "Fehler" ohne Grundangabe war
            // nicht bedienbar (SearXNG-Bug) – der Nutzer wusste nicht, ob URL, Port, Docker-
            // Mapping oder die JSON-API das Problem ist.
            let result = await viewModel.testSearxngConnection(baseURL: url)
            await MainActor.run {
                self.isPinging = false
                self.pingStatus = result.diagnostic
                // Erfolg kurz zeigen, Diagnosen stehen lassen (bis zur nächsten Änderung),
                // damit die konkreten Lösungsschritte lesbar bleiben.
                if result == .ok {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if self.pingStatus != nil { self.pingStatus = nil }
                    }
                }
            }
        }
    }

    var body: some View {
        settingsSection(icon: "magnifyingglass", title: "Websuche & Browsing") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Suche & Browsing aktivieren", isOn: searchAndBrowsingBinding)
                    .toggleStyle(.switch)
                    .font(.caption.bold())
                    .settingHelp("Aktiviert die Web-Suchfunktion und den integrierten Browser, damit das Modell aktuelle Informationen abrufen kann.")

                if viewModel.searchEnabled {
                    labeledField("SearXNG-URL / Such-IP") {
                        HStack(spacing: 8) {
                            TextField("http://127.0.0.1:8082 oder http://<tailscale-host>:8082", text: $viewModel.searxngURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .settingHelp("Auf dem Docker-Mac: http://127.0.0.1:8082. Von einem anderen Mac: Tailscale-Hostname/IP des Docker-Macs mit :8082. Leer lassen aktiviert bewusst DuckDuckGo als einfachen Fallback.")
                                .onChange(of: viewModel.searxngURL) { _ in
                                    viewModel.syncToolRegistry()
                                    viewModel.saveSettings()
                                }

                            // Prüft NICHT nur, ob der Port offen ist, sondern ob unter der URL
                            // tatsächlich eine SearXNG-Instanz mit gültigen JSON-Suchergebnissen
                            // antwortet – genau die Sorte Port-/Host-Verwechslung (z.B. localhost
                            // auf einem anderen Mac statt der Tailscale-Adresse), die sich sonst
                            // erst beim nächsten echten Tool-Aufruf im Chat gezeigt hätte.
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
                            .disabled(isPinging || viewModel.searxngURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    labeledField("Max. Zeichen beim Browsen") {
                        HStack {
                            TextField("10000", value: $viewModel.maxBrowseCharacters, formatter: NumberFormatter())
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .onChange(of: viewModel.maxBrowseCharacters) { _ in
                                    viewModel.syncToolRegistry()
                                    viewModel.saveSettings()
                                }
                            Text("Zeichen")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .settingHelp("Browsing nutzt das eingestellte Zeichen-Limit, um das Kontext-Fenster zu schonen.")
                    }
                }
            }
        }
    }
}
