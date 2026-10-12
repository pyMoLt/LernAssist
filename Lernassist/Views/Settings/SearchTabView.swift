import SwiftUI

// MARK: - SearchTabView
// Websuche: SearXNG, Quellen, Exa, Reranker, Belege, Domains.

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
        VStack(alignment: .leading, spacing: DS.Space.l) {
            searxngSection
            if viewModel.searchEnabled {
                ResearchSettingsSections(viewModel: viewModel)
            }
        }
    }

    private var searxngSection: some View {
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
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .settingHelp("Browsing nutzt das eingestellte Zeichen-Limit, um das Kontext-Fenster zu schonen.")
                    }
                }
            }
        }
    }
}


// MARK: - Recherche-Einstellungen

private struct ResearchSettingsSections: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var rerankStatus: String?
    @State private var isTestingReranker = false

    private var omlxProfiles: [EndpointProfile] { viewModel.profiles.filter { $0.provider == .omlx } }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            settingsSection(icon: "square.stack.3d.up", title: "Quellen") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ResearchSource.allCases) { source in
                        Toggle(isOn: Binding(
                            get: { viewModel.research.enabledSources.contains(source) },
                            set: { on in
                                if on { viewModel.research.enabledSources.insert(source) }
                                else { viewModel.research.enabledSources.remove(source) }
                            })) {
                            Label(source.label, systemImage: source.systemImage)
                        }
                        .toggleStyle(.switch)
                        .settingHelp(source.help)
                    }
                    Divider()
                    labeledField("Kontakt-E-Mail für Fach-APIs (empfohlen)") {
                        TextField("name@beispiel.de", text: $viewModel.research.apiContactEmail)
                            .textFieldStyle(.roundedBorder)
                            .settingHelp("Wird nur Wikipedia, Europe PMC, arXiv und Stack Exchange als Teil der App-Kennung mitgeschickt. Wikimedia empfiehlt eine Kontaktangabe – das senkt das Risiko, als Bot gesperrt zu werden.")
                    }
                    HStack {
                        labeledField("Wikipedia-Sprache") {
                            Picker("", selection: $viewModel.research.wikipediaLanguage) {
                                Text("Deutsch").tag("de")
                                Text("Englisch").tag("en")
                            }
                            .labelsHidden().frame(width: 120)
                        }
                        labeledField("Stack-Exchange-Seiten (Komma)") {
                            TextField("stackoverflow, math, physics", text: Binding(
                                get: { viewModel.research.stackExchangeSites.joined(separator: ", ") },
                                set: { viewModel.research.stackExchangeSites = Self.list($0) }))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }

            settingsSection(icon: ResearchSource.exa.systemImage, title: "Exa (Fallback)") {
                VStack(alignment: .leading, spacing: 8) {
                    labeledField("Exa-API-Key (optional)") {
                        SecureField("leer = kostenlose Stufe", text: $viewModel.exaAPIKey)
                            .textFieldStyle(.roundedBorder)
                            .settingHelp("Ohne Key nutzt LernAssist die kostenlose, rate-limitierte Stufe des Exa-MCP. Der Key liegt im Schlüsselbund.")
                    }
                    Stepper(value: $viewModel.research.exaMinWebResults, in: 1...10) {
                        Text("Exa fragen, wenn SearXNG weniger als \(viewModel.research.exaMinWebResults) Treffer liefert")
                            .font(.caption)
                    }
                    .settingHelp("Exa ist nur ein Fallback: Es wird erst gefragt, wenn die normale Websuche zu wenig findet.")
                }
            }

            settingsSection(icon: "arrow.up.arrow.down", title: "Ranking") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Reranker", selection: $viewModel.research.rerankerMode) {
                        ForEach(RerankerMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .settingHelp("Erst filtert eine Keyword-Relevanz (BM25) die Absätze, dann sortiert der Reranker sie neu. Ist er nicht erreichbar, gilt automatisch die Keyword-Reihenfolge.")
                    if viewModel.research.rerankerMode == .auto {
                        HStack {
                            labeledField("Reranker-Modell") {
                                TextField("Qwen3-Reranker-0.6B-8bit-mlx", text: $viewModel.research.rerankerModel)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.caption, design: .monospaced))
                            }
                            labeledField("über oMLX-Profil") {
                                Picker("", selection: $viewModel.research.rerankerProfileID) {
                                    Text("automatisch").tag(UUID?.none)
                                    ForEach(omlxProfiles) { Text($0.name).tag(UUID?.some($0.id)) }
                                }
                                .labelsHidden().frame(width: 160)
                            }
                            Button(action: testReranker) {
                                if isTestingReranker { ProgressView().controlSize(.mini) } else { Text("Testen").font(.caption2) }
                            }
                            .buttonStyle(.bordered)
                            .padding(.top, 14)
                        }
                        if omlxProfiles.isEmpty {
                            Text("Kein oMLX-Profil vorhanden – der Reranker braucht ein oMLX-Profil (Einstellungen → Endpunkte).")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        if let rerankStatus {
                            Text(rerankStatus).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            settingsSection(icon: "text.quote", title: "Belege an das Modell") {
                VStack(alignment: .leading, spacing: 6) {
                    stepper("Max. Absätze", value: $viewModel.research.maxPassages, range: 2...20)
                    stepper("Max. Absätze pro Quelle", value: $viewModel.research.maxPassagesPerSource, range: 1...5)
                    stepper("Token-Budget der Belege", value: $viewModel.research.tokenBudget, range: 500...12_000, step: 250)
                    stepper("Absatzlänge (Zeichen)", value: $viewModel.research.passageChars, range: 250...1_500, step: 50)
                    stepper("Volltexte laden (Seiten)", value: $viewModel.research.fullTextPages, range: 0...8)
                    stepper("Treffer pro Quelle", value: $viewModel.research.resultsPerSource, range: 2...15)
                }
                .settingHelp("Die Suche schickt nur die relevantesten Absätze mit Quellennummer [W#] an das Modell. Kleinere Werte sparen Kontext, größere geben mehr Material.")
            }

            settingsSection(icon: "checkmark.shield", title: "Domains") {
                VStack(alignment: .leading, spacing: 8) {
                    domainField("Vertrauenswürdig (stärkerer Bonus)", \.trustedDomains)
                    domainField("Gute Quellen (leichter Bonus)", \.goodDomains)
                    domainField("Gesperrt", \.blockedDomains)
                }
                .settingHelp("Domains mit Komma trennen. Unterseiten zählen mit (z. B. „wikipedia.org“).")
            }
        }
    }

    private func stepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text("\(value.wrappedValue)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private func domainField(_ title: String, _ keyPath: WritableKeyPath<ResearchSettings, [String]>) -> some View {
        labeledField(title) {
            TextField("domain.de, …", text: Binding(
                get: { viewModel.research[keyPath: keyPath].joined(separator: ", ") },
                set: { viewModel.research[keyPath: keyPath] = Self.list($0) }), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .lineLimit(1...4)
        }
    }

    static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    private func testReranker() {
        let settings = viewModel.research
        guard let profile = viewModel.profiles.first(where: { $0.id == settings.rerankerProfileID })
                ?? viewModel.activeProfile.flatMap({ $0.provider == .omlx ? $0 : nil })
                ?? omlxProfiles.first else {
            rerankStatus = "Kein oMLX-Profil gefunden."
            return
        }
        isTestingReranker = true
        rerankStatus = nil
        Task {
            let reranker = OMLXReranker(profile: profile, model: settings.rerankerModel, timeout: settings.rerankerTimeout)
            let start = Date()
            let status: String
            do {
                let scores = try await reranker.scores(query: "Wo findet der Citratzyklus statt?",
                                                       documents: ["Der Citratzyklus läuft in der Mitochondrienmatrix ab.", "Paris ist die Hauptstadt Frankreichs."])
                let ok = scores.count == 2 && scores[0] > scores[1]
                status = (ok ? "OK ✓ " : "Antwort unplausibel ") + String(format: "(%.1f s, Scores %.2f / %.2f)", Date().timeIntervalSince(start), scores.first ?? 0, scores.last ?? 0)
            } catch {
                status = "Fehler: \(error.localizedDescription)"
            }
            await MainActor.run {
                rerankStatus = status
                isTestingReranker = false
            }
        }
    }
}
