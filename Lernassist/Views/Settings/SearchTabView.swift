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
        settingsSection(icon: "magnifyingglass", title: "Websuche & Browsing", tint: DS.Accent.cyan) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                SettingsRow(
                    title: "Websuche & integriertes Browsing",
                    subtitle: "Erlaubt dem Modell, aktuelle Fakten und Fachquellen live abzurufen.",
                    icon: "globe",
                    tint: DS.Accent.cyan
                ) {
                    Toggle("", isOn: searchAndBrowsingBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .settingHelp("Aktiviert die Web-Suchfunktion und den integrierten Browser, damit das Modell aktuelle Informationen abrufen kann.")
                }

                if viewModel.searchEnabled {
                    SettingsHairline()

                    HStack(alignment: .top, spacing: DS.Space.m) {
                        labeledField("SearXNG-URL / Such-Server") {
                            HStack(spacing: DS.Space.s) {
                                TextField("http://127.0.0.1:8082 oder http://<tailscale-host>:8082", text: $viewModel.searxngURL)
                                    .modifier(SettingsFieldStyle(monospaced: true))
                                    .settingHelp("Auf dem Rechner mit dem SearXNG-Container: http://127.0.0.1:8082. Von einem anderen Gerät: Hostname oder IP dieses Rechners mit :8082 (z. B. über Tailscale). Leer lassen aktiviert bewusst DuckDuckGo als einfachen Fallback.")
                                    .onChange(of: viewModel.searxngURL) { _, _ in
                                        viewModel.syncToolRegistry()
                                        viewModel.saveSettings()
                                    }

                                Button(action: ping) {
                                    HStack(spacing: 4) {
                                        if isPinging {
                                            ProgressView().controlSize(.mini).scaleEffect(0.75)
                                        } else {
                                            Circle()
                                                .fill((pingStatus?.hasPrefix("OK") == true) ? DS.Accent.emerald : DS.Accent.cyan)
                                                .frame(width: 6, height: 6)
                                        }
                                        Text(pingStatus?.hasPrefix("OK") == true ? "OK ✓" : "Ping")
                                    }
                                }
                                .buttonStyle(SoftActionButtonStyle(tint: (pingStatus?.hasPrefix("OK") == true) ? DS.Accent.emerald : DS.Ink.primary))
                                .disabled(isPinging || viewModel.searxngURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        .frame(maxWidth: .infinity)

                        labeledField("Max. Zeichen pro Webseite") {
                            TextField("10000", value: $viewModel.maxBrowseCharacters, formatter: NumberFormatter())
                                .modifier(SettingsFieldStyle(monospaced: true))
                                .onChange(of: viewModel.maxBrowseCharacters) { _, _ in
                                    viewModel.syncToolRegistry()
                                    viewModel.saveSettings()
                                }
                                .settingHelp("Browsing nutzt das eingestellte Zeichen-Limit, um das Kontext-Fenster zu schonen.")
                        }
                        .frame(width: 175)
                    }

                    if let status = pingStatus, !status.hasPrefix("OK") {
                        Text(status)
                            .font(.caption2)
                            .foregroundStyle(DS.Accent.rose)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}


// MARK: - Recherche-Einstellungen

private struct ResearchSettingsSections: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject private var usage = ResearchUsageStore.shared
    @State private var rerankStatus: String?
    @State private var isTestingReranker = false

    /// Letzte Nutzung bzw. letzter Fehler von Exa in einer Zeile.
    private var exaUsageSubtitle: String {
        guard let entry = usage.entry(.exa) else { return "Noch keine Exa-Suche. Exa springt nur ein, wenn SearXNG zu wenig findet." }
        let format = Date.RelativeFormatStyle(presentation: .named).locale(Locale(identifier: "de_DE"))
        if let error = entry.lastError, let at = entry.lastErrorAt, at >= (entry.lastUsedAt ?? at) {
            return "Letzter Fehler \(at.formatted(format)): \(error)"
        }
        if let used = entry.lastUsedAt { return "Zuletzt genutzt \(used.formatted(format))." }
        return "Exa springt nur ein, wenn SearXNG zu wenig findet."
    }

    private var omlxProfiles: [EndpointProfile] { viewModel.profiles.filter { $0.provider == .omlx } }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            settingsSection(icon: "square.stack.3d.up.fill", title: "Fachquellen & Wissensdatenbanken", tint: DS.Accent.indigo) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    ForEach(ResearchSource.allCases) { source in
                        SettingsRow(
                            title: source.label,
                            subtitle: source.help,
                            icon: source.systemImage,
                            tint: DS.Accent.indigo
                        ) {
                            HStack(spacing: DS.Space.s) {
                                if usage.thisMonth(source) > 0 {
                                    UsageBadge(today: usage.today(source), month: usage.thisMonth(source))
                                }
                                Toggle("", isOn: Binding(
                                    get: { viewModel.research.enabledSources.contains(source) },
                                    set: { on in
                                        if on { viewModel.research.enabledSources.insert(source) }
                                        else { viewModel.research.enabledSources.remove(source) }
                                    }
                                ))
                                .toggleStyle(.switch)
                                .labelsHidden()
                            }
                        }
                        if source.id != ResearchSource.allCases.last?.id {
                            SettingsHairline()
                        }
                    }

                    SettingsHairline()
                        .padding(.vertical, 4)

                    HStack(alignment: .top, spacing: DS.Space.m) {
                        labeledField("Kontakt-E-Mail für Fach-APIs (empfohlen)") {
                            TextField("name@beispiel.de", text: $viewModel.research.apiContactEmail)
                                .modifier(SettingsFieldStyle())
                                .settingHelp("Wird nur Wikipedia, Europe PMC, arXiv und Stack Exchange als Teil der App-Kennung mitgeschickt. Wikimedia empfiehlt eine Kontaktangabe – das senkt das Risiko, als Bot gesperrt zu werden. Bleibt lokal in den Einstellungen dieses Macs und steht nie im Code.")
                        }
                        .frame(maxWidth: .infinity)

                        labeledField("Wikipedia-Sprache") {
                            SoftDropdownMenu(label: viewModel.research.wikipediaLanguage == "en" ? "Englisch" : "Deutsch") {
                                Button {
                                    viewModel.research.wikipediaLanguage = "de"
                                } label: {
                                    if viewModel.research.wikipediaLanguage == "de" {
                                        Label("Deutsch", systemImage: "checkmark")
                                    } else {
                                        Text("Deutsch")
                                    }
                                }
                                Button {
                                    viewModel.research.wikipediaLanguage = "en"
                                } label: {
                                    if viewModel.research.wikipediaLanguage == "en" {
                                        Label("Englisch", systemImage: "checkmark")
                                    } else {
                                        Text("Englisch")
                                    }
                                }
                            }
                        }
                        .frame(width: 150)
                    }

                    labeledField("Stack-Exchange-Seiten (Kommagetrennt)") {
                        TextField("stackoverflow, math, physics", text: Binding(
                            get: { viewModel.research.stackExchangeSites.joined(separator: ", ") },
                            set: { viewModel.research.stackExchangeSites = Self.list($0) }))
                            .modifier(SettingsFieldStyle())
                    }
                }
            }

            settingsSection(icon: ResearchSource.exa.systemImage, title: "Exa Semantischer Fallback", tint: DS.Accent.amber) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    labeledField("Exa-API-Key (optional)") {
                        SecureField("Leer = kostenlose Stufe", text: $viewModel.exaAPIKey)
                            .modifier(SettingsFieldStyle())
                            .settingHelp("Ohne Key nutzt LernAssist die kostenlose, rate-limitierte Stufe des Exa-MCP. Der Key liegt im Schlüsselbund.")
                    }

                    SettingsRow(
                        title: "Nutzung",
                        subtitle: exaUsageSubtitle,
                        icon: "chart.bar",
                        tint: DS.Accent.amber,
                        help: "Zählt die Exa-Suchen dieser App (heute und diesen Monat), mit oder ohne Key. Wie viel von der kostenlosen Stufe noch übrig ist, gibt Exa nicht heraus – mit Key zeigt das Exa-Dashboard den Verbrauch."
                    ) {
                        UsageBadge(today: usage.today(.exa), month: usage.thisMonth(.exa), tint: DS.Accent.amber)
                    }

                    SettingsRow(
                        title: "Fallback-Schwelle für Exa",
                        subtitle: "Exa wird befragt, wenn SearXNG weniger als \(viewModel.research.exaMinWebResults) Treffer liefert."
                    ) {
                        Stepper("", value: $viewModel.research.exaMinWebResults, in: 1...10)
                            .labelsHidden()
                    }
                }
            }

            settingsSection(icon: "arrow.up.arrow.down.circle.fill", title: "Relevanz-Ranking (BM25 + Reranker)", tint: DS.Accent.emerald) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    SettingsRow(
                        title: "Reranker-Modus",
                        subtitle: "Sortiert gefundene Textabsätze nach semantischer Relevanz zur Frage."
                    ) {
                        SoftDropdownMenu(label: viewModel.research.rerankerMode.label, width: 210) {
                            ForEach(RerankerMode.allCases, id: \.self) { mode in
                                Button {
                                    viewModel.research.rerankerMode = mode
                                } label: {
                                    if viewModel.research.rerankerMode == mode {
                                        Label(mode.label, systemImage: "checkmark")
                                    } else {
                                        Text(mode.label)
                                    }
                                }
                            }
                        }
                    }

                    if viewModel.research.rerankerMode == .auto {
                        SettingsHairline()

                        HStack(alignment: .bottom, spacing: DS.Space.m) {
                            labeledField("Reranker-Modell") {
                                TextField("Qwen3-Reranker-0.6B-8bit-mlx", text: $viewModel.research.rerankerModel)
                                    .modifier(SettingsFieldStyle(monospaced: true))
                            }
                            .frame(maxWidth: .infinity)

                            labeledField("oMLX-Profil") {
                                SoftDropdownMenu(
                                    label: omlxProfiles.first(where: { $0.id == viewModel.research.rerankerProfileID })?.name ?? "Automatisch"
                                ) {
                                    Button {
                                        viewModel.research.rerankerProfileID = nil
                                    } label: {
                                        if viewModel.research.rerankerProfileID == nil {
                                            Label("Automatisch", systemImage: "checkmark")
                                        } else {
                                            Text("Automatisch")
                                        }
                                    }
                                    Divider()
                                    ForEach(omlxProfiles) { p in
                                        Button {
                                            viewModel.research.rerankerProfileID = p.id
                                        } label: {
                                            if viewModel.research.rerankerProfileID == p.id {
                                                Label(p.name, systemImage: "checkmark")
                                            } else {
                                                Text(p.name)
                                            }
                                        }
                                    }
                                }
                            }
                            .frame(width: 165)

                            Button(action: testReranker) {
                                if isTestingReranker {
                                    ProgressView().controlSize(.mini).scaleEffect(0.75)
                                } else {
                                    Text("Testen")
                                }
                            }
                            .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.emerald))
                        }

                        if omlxProfiles.isEmpty {
                            Text("Kein oMLX-Profil vorhanden – der Reranker braucht ein oMLX-Profil (Einstellungen → Endpunkte).")
                                .font(.caption2).foregroundStyle(DS.Accent.amber)
                        }
                        if let rerankStatus {
                            Text(rerankStatus).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            settingsSection(icon: "photo.on.rectangle.angled", title: "Abbildungen aus der Recherche", tint: DS.Accent.emerald) {
                SettingsRow(
                    title: "Abbildungen anbieten",
                    subtitle: "Passende Bilder aus Wikipedia, Webseiten und Fachartikeln. Das Modell zeigt eins mit [B#], die App fügt es mit Quelle in die Antwort ein.",
                    icon: "photo",
                    tint: DS.Accent.emerald,
                    help: "Nur echte Bilder mit Bildunterschrift oder aussagekräftigem Alt-Text, mindestens 200 × 150 Pixel, höchstens 8 MB, keine Logos oder Icons, keine lokalen Adressen. Höchstens 3 pro Seite und 6 pro Suche; ist der Reranker an, wählt er die passendsten aus."
                ) {
                    Toggle("", isOn: $viewModel.research.imagesEnabled).toggleStyle(.switch).labelsHidden()
                }
            }

            settingsSection(icon: "text.quote", title: "Beleg-Budget für das Modell", tint: DS.Accent.blue) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    stepper("Max. Absätze gesamt", value: $viewModel.research.maxPassages, range: 2...20)
                    SettingsHairline()
                    stepper("Max. Absätze pro Quelle", value: $viewModel.research.maxPassagesPerSource, range: 1...5)
                    SettingsHairline()
                    stepper("Token-Budget der Belege", value: $viewModel.research.tokenBudget, range: 500...12_000, step: 250)
                    SettingsHairline()
                    stepper("Absatzlänge (Zeichen)", value: $viewModel.research.passageChars, range: 250...1_500, step: 50)
                    SettingsHairline()
                    stepper("Volltexte laden (Seiten)", value: $viewModel.research.fullTextPages, range: 0...8)
                    SettingsHairline()
                    stepper("Treffer pro Quelle", value: $viewModel.research.resultsPerSource, range: 2...15)
                }
                .settingHelp("Die Suche schickt nur die relevantesten Absätze mit Quellennummer [W#] an das Modell. Kleinere Werte sparen Kontext, größere geben mehr Material.")
            }

            settingsSection(icon: "checkmark.shield.fill", title: "Domain-Gewichtung & Filter", tint: DS.Accent.indigo) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    domainField("Vertrauenswürdig (stärkerer Bonus)", \.trustedDomains)
                    domainField("Gute Quellen (leichter Bonus)", \.goodDomains)
                    domainField("Blockierte Domains", \.blockedDomains)
                }
                .settingHelp("Domains mit Komma trennen. Unterseiten zählen mit (z. B. „wikipedia.org“).")
            }

            SettingsDisclosureSection(
                title: "Erweitert (Recherche & Ranking)",
                subtitle: "Download-Timeouts, Dateigrößen, Reranker-Fenster und Cache-Dauer",
                icon: "slider.horizontal.3",
                tint: DS.Accent.cyan
            ) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    SettingsRow(
                        title: "Webseiten-Download Timeout",
                        subtitle: "Maximalzeit für das Laden einer Webseite oder eines Online-PDFs.",
                        icon: "timer",
                        tint: DS.Accent.cyan,
                        help: "Höhere Werte helfen bei langsamen Servern oder unzuverlässiger Internetverbindung (5–60 s, Standard 15 s)."
                    ) {
                        stepperBadge("\(Int(viewModel.research.fetchTimeout)) s", value: Binding(
                            get: { Int(viewModel.research.fetchTimeout) },
                            set: { viewModel.research.fetchTimeout = Double($0) }
                        ), range: 5...60, step: 5)
                    }

                    SettingsHairline()

                    SettingsRow(
                        title: "Max. Download-Größe",
                        subtitle: "Maximale Dateigröße für Webseiten und PDFs bei der Recherche.",
                        icon: "arrow.down.doc",
                        tint: DS.Accent.cyan,
                        help: "Schützt vor übermäßig großen Downloads bei der Websuche (1–50 MB, Standard 10 MB)."
                    ) {
                        stepperBadge("\(Int(viewModel.research.maxDownloadMB)) MB", value: Binding(
                            get: { Int(viewModel.research.maxDownloadMB) },
                            set: { viewModel.research.maxDownloadMB = Double($0) }
                        ), range: 1...50, step: 5)
                    }

                    SettingsHairline()

                    SettingsRow(
                        title: "Reranker-Kandidatenfenster",
                        subtitle: "Wie viele der besten Textstellen an den lokalen Reranker übergeben werden.",
                        icon: "list.number",
                        tint: DS.Accent.emerald,
                        help: "Trade-off zwischen Reranking-Genauigkeit und Geschwindigkeit bei langen Seiten (10–200, Standard 60)."
                    ) {
                        stepperBadge("\(viewModel.research.rerankerWindow)", value: $viewModel.research.rerankerWindow, range: 10...200, step: 10)
                    }

                    SettingsHairline()

                    SettingsRow(
                        title: "Reranker-Timeout",
                        subtitle: "Maximale Wartezeit für den lokalen Reranker pro Anfrage.",
                        icon: "hourglass",
                        tint: DS.Accent.emerald,
                        help: "Timeout für den oMLX-Reranker; bei Überschreitung wird die Keyword-Relevanz verwendet (2–30 s, Standard 8 s)."
                    ) {
                        stepperBadge("\(Int(viewModel.research.rerankerTimeout)) s", value: Binding(
                            get: { Int(viewModel.research.rerankerTimeout) },
                            set: { viewModel.research.rerankerTimeout = Double($0) }
                        ), range: 2...30, step: 1)
                    }

                    SettingsHairline()

                    SettingsRow(
                        title: "Recherche-Cache Dauer",
                        subtitle: "Wie lange Suchergebnisse und Webseiten gecacht bleiben.",
                        icon: "clock.arrow.circlepath",
                        tint: DS.Accent.cyan,
                        help: "Wiederholte Suchen nach denselben Themen nutzen den Cache (1–60 min, Standard 10 min)."
                    ) {
                        stepperBadge("\(viewModel.research.cacheMinutes) min", value: $viewModel.research.cacheMinutes, range: 1...60, step: 5)
                    }
                }
            }
        }
    }

    private func stepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1) -> some View {
        SettingsRow(title: title) {
            HStack(spacing: DS.Space.s) {
                Text("\(value.wrappedValue)")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(DS.Accent.indigo)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Surface.control))
                Stepper("", value: value, in: range, step: step)
                    .labelsHidden()
            }
        }
    }

    private func domainField(_ title: String, _ keyPath: WritableKeyPath<ResearchSettings, [String]>) -> some View {
        labeledField(title) {
            TextField("domain.de, …", text: Binding(
                get: { viewModel.research[keyPath: keyPath].joined(separator: ", ") },
                set: { viewModel.research[keyPath: keyPath] = Self.list($0) }), axis: .vertical)
                .modifier(SettingsFieldStyle())
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

/// Suchen einer Quelle: „heute“ und „Monat“, kompakt und einzeilig – große Zahlen werden gekürzt
/// („1,2k“), damit die Zeile nie umbricht.
struct UsageBadge: View {
    let today: Int
    let month: Int
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 6) {
            part("heute", today)
            Text("·").foregroundStyle(.tertiary)
            part("Monat", month)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.10)))
        .help("Suchen dieser App über diese Quelle: heute \(today), diesen Monat \(month)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heute \(today) Suchen, diesen Monat \(month)")
    }

    private func part(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.secondary)
            Text(Self.compact(value)).fontWeight(.semibold).foregroundStyle(tint == .secondary ? Color.primary : tint)
        }
    }

    /// 999 → „999“, 1.234 → „1,2k“, 12.345 → „12k“, 1.234.567 → „1,2M“.
    static func compact(_ value: Int) -> String {
        func format(_ v: Double, _ suffix: String) -> String {
            let text = v < 10 ? String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") : String(Int(v))
            return text.replacingOccurrences(of: ",0", with: "") + suffix
        }
        switch value {
        case ..<1_000: return "\(value)"
        case ..<1_000_000: return format(Double(value) / 1_000, "k")
        default: return format(Double(value) / 1_000_000, "M")
        }
    }
}
