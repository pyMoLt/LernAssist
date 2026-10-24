import SwiftUI

// MARK: - ToolsTabView

struct ToolsTabView: View {
    @ObservedObject var viewModel: ChatViewModel
    // Wir nutzen @State für lokale UI-Zustände; Änderungen werden über viewModel.syncToolRegistry() gepusht
    @State private var toolStates: [String: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            settingsSection(icon: "wrench.and.screwdriver.fill", title: L("Integrierte KI-Werkzeuge"), tint: DS.Accent.emerald) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text(L("Deaktivierte Tools tauchen weder im API-Schema noch im System-Prompt auf – sie verbrauchen kein Kontext-Budget."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)

                    ForEach(Array(ToolRegistry.shared.tools.enumerated()), id: \.element.name) { idx, tool in
                        if idx > 0 { SettingsHairline() }
                        ToolToggleRow(tool: tool, isEnabled: binding(for: tool))
                    }
                }
            }

            // Konfiguration von SearXNG-URL und Zeichen-Limit lebt nur im Tab „Recherche“.
            if toolStates["coding_sandbox"] ?? true {
                settingsSection(icon: "terminal.fill", title: L("Python-Sandbox (coding_sandbox)"), tint: DS.Accent.indigo) {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        HStack(spacing: DS.Space.s) {
                            Image(systemName: pythonStatusSymbol)
                                .foregroundStyle(pythonStatusColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(viewModel.pythonEnvironmentStatus.label)
                                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                                Text(L("Eigenes Python \(PythonEnvironmentInstaller.pythonVersion) (über uv). Vorinstalliert: \(PythonEnvironmentInstaller.basePackages.joined(separator: ", "))."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Button(L("Neu einrichten")) { viewModel.setupPythonEnvironment(force: true) }
                                .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.indigo))
                                .disabled({ if case .installing = viewModel.pythonEnvironmentStatus { return true }; return false }())
                        }

                        SettingsHairline()

                        SettingsRow(
                            title: L("Fehlende PyPI-Pakete automatisch installieren"),
                            subtitle: L("Erlaubt der Sandbox, benötigte Standard-Bibliotheken ohne Rückfrage nachzuladen.")
                        ) {
                            Toggle("", isOn: $viewModel.autoInstallPythonPackages)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .settingHelp(L("Das Modell kann fehlende Pakete selbst nachinstallieren (nur fertige Pakete von PyPI, kein Setup-Code). Aus = jedes Mal nachfragen."))
                        }

                    }
                }
            }

            if toolStates["web_search"] == true || toolStates["browse_url"] == true {
                settingsSection(icon: "magnifyingglass", title: L("Websuche & URL-Browsing"), tint: DS.Accent.cyan) {
                    Text(L("SearXNG-URL, Fachquellen und das Zeichen-Limit fürs URL-Browsing werden im Tab „Recherche“ konfiguriert."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if toolStates["coding_sandbox"] ?? true {
                PythonInternetSection(viewModel: viewModel)
                HTMLLibrariesSection(viewModel: viewModel)
            }

            SettingsDisclosureSection(
                title: L("Erweitert (Tools & Sandbox)"),
                subtitle: L("Tool-Rundenlimits, Python-Laufzeiten, Skript-Aufbewahrung und Seiten-Cache"),
                icon: "slider.horizontal.3",
                tint: DS.Accent.emerald
            ) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    SettingsRow(
                        title: L("Max. Tool-Runden pro Frage"),
                        subtitle: L("Obergrenze aufeinanderfolgender Werkzeug-Runden vor der finalen Antwort."),
                        icon: "arrow.2.squarepath",
                        tint: DS.Accent.emerald,
                        help: L("Schützt vor Endlosschleifen. Beim Erreichen des Limits antwortet das Modell mit den bisherigen Erkenntnissen (1–25, Standard 8).")
                    ) {
                        stepperBadge("\(viewModel.maxToolRounds)", value: $viewModel.maxToolRounds, range: 1...25)
                    }

                    SettingsHairline()

                    SettingsRow(
                        title: L("Python-Sandbox Timeout"),
                        subtitle: L("Maximale Laufzeit für ein Python-Skript, bevor es abgebrochen wird."),
                        icon: "timer",
                        tint: DS.Accent.indigo,
                        help: L("Verhindert ein Einfrieren bei Endlosschleifen oder rechenintensiven Aufgaben (10–600 s, Standard 150 s).")
                    ) {
                        stepperBadge("\(Int(viewModel.pythonSandboxTimeout)) s", value: Binding(
                            get: { Int(viewModel.pythonSandboxTimeout) },
                            set: { viewModel.pythonSandboxTimeout = Double($0) }
                        ), range: 10...600, step: 10)
                    }

                    SettingsHairline()

                    SettingsRow(
                        title: L("Max. Ausgabe-Länge"),
                        subtitle: L("Maximale Textmenge (stdout/stderr), die an das Modell zurückgeht."),
                        icon: "text.alignleft",
                        tint: DS.Accent.indigo,
                        help: L("Schützt den Kontext vor riesigen Terminal-Ausgaben. Tracebacks und Fehlermeldungen am Ende bleiben erhalten.")
                    ) {
                        stepperBadge("\(viewModel.pythonMaxOutputCharacters)", value: $viewModel.pythonMaxOutputCharacters, range: 1_000...50_000, step: 1_000)
                    }

                    SettingsHairline()

                    SettingsRow(
                        title: L("Aufbewahrte Skript-Versionen"),
                        subtitle: L("Anzahl gespeicherter Skripte (script_vN.py) im Chat-Ordner."),
                        icon: "doc.on.doc",
                        tint: DS.Accent.indigo,
                        help: L("Erlaubt dem Modell, frühere Skriptversionen iterativ einzusehen und zu verbessern (3–50, Standard 10).")
                    ) {
                        stepperBadge("\(viewModel.pythonMaxScriptVersions)", value: $viewModel.pythonMaxScriptVersions, range: 3...50)
                    }

                    SettingsHairline()

                    SettingsRow(
                        title: L("Plot-Auflösung (DPI)"),
                        subtitle: L("Auflösung generierter Matplotlib-Diagramme für den Chat."),
                        icon: "photo",
                        tint: DS.Accent.indigo,
                        help: L("Höhere DPI liefern schärfere Diagramme, erzeugen aber größere Bilddateien (100–300 dpi, Standard 150 dpi).")
                    ) {
                        stepperBadge(L("\(viewModel.pythonPlotDpi) dpi"), value: $viewModel.pythonPlotDpi, range: 100...300, step: 25)
                    }

                    SettingsHairline()

                    SettingsRow(
                        title: L("Seiten-Cache Dauer"),
                        subtitle: L("Wie lange gelesene Webseiten im Arbeitsspeicher vorgehalten werden."),
                        icon: "clock.arrow.circlepath",
                        tint: DS.Accent.cyan,
                        help: L("Erlaubt Folgefragen zu einer geöffneten Webseite ohne erneuten Download (60–3600 s, Standard 600 s / 10 min).")
                    ) {
                        stepperBadge(L("\(Int(viewModel.documentCacheDuration / 60)) min"), value: Binding(
                            get: { Int(viewModel.documentCacheDuration / 60) },
                            set: { viewModel.documentCacheDuration = Double($0 * 60) }
                        ), range: 1...60, step: 1)
                    }
                }
            }
        }
        .onAppear { loadStates() }
        .onChange(of: toolStates) { _, _ in applyStates() }
    }

    private var pythonStatusSymbol: String {
        switch viewModel.pythonEnvironmentStatus {
        case .ready: return "checkmark.circle.fill"
        case .installing: return "arrow.down.circle"
        case .failed: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var pythonStatusColor: Color {
        switch viewModel.pythonEnvironmentStatus {
        case .ready: return DS.Accent.emerald
        case .installing: return DS.Accent.indigo
        case .failed: return DS.Accent.amber
        case .unknown: return .secondary
        }
    }

    // MARK: - Binding-Helfer

    private func binding(for tool: AppTool) -> Binding<Bool> {
        Binding(
            get: { toolStates[tool.name] ?? tool.isEnabled },
            set: { newVal in
                toolStates[tool.name] = newVal
                tool.isEnabled = newVal
                viewModel.saveSettings()
                viewModel.syncToolRegistry()
                if tool.name == "web_search" { viewModel.searchEnabled = newVal }
            }
        )
    }

    private func loadStates() {
        toolStates = Dictionary(uniqueKeysWithValues: ToolRegistry.shared.tools.map { ($0.name, $0.isEnabled) })
    }

    private func applyStates() {
        ToolRegistry.shared.loadEnabledStates(from: toolStates)
        viewModel.syncToolRegistry()
    }
}

// MARK: - Tool-Zeile

private struct ToolToggleRow: View {
    let tool: AppTool
    @Binding var isEnabled: Bool

    var body: some View {
        SettingsRow(
            title: tool.displayName,
            subtitle: L("Tool-ID: \(tool.name)")
        ) {
            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

// MARK: - Internet für Python

/// Erweitert: Internet für die Python-Sandbox (Proxy der App). Domains, Größe, Anzahl, Dateitypen.
private struct PythonInternetSection: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var newDomain = ""

    var body: some View {
        SettingsDisclosureSection(
            title: L("Erweitert (Internet für Python)"),
            subtitle: L("Downloads aus Python-Skripten: erlaubte Domains, Größe, Anzahl und Dateitypen"),
            icon: "network",
            tint: DS.Accent.indigo
        ) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                SettingsRow(
                    title: L("Internet für Python"),
                    subtitle: L("Python lädt Daten nur über https. Jede neue Domain bestätigst du einmal (Einmal, Immer, Ablehnen)."),
                    icon: "network",
                    tint: DS.Accent.indigo,
                    help: L("Python verbindet sich nur mit einem Proxy der App. Lokale Adressen und dein Tailnet sind immer gesperrt. Heruntergeladene Programme, Installer und Skripte werden nach dem Lauf entfernt und nie ausgeführt.")
                ) {
                    Toggle("", isOn: $viewModel.pythonInternetEnabled).toggleStyle(.switch).labelsHidden()
                }

                if viewModel.pythonInternetEnabled {
                    SettingsHairline()

                    SettingsRow(
                        title: L("Höchstgröße pro Download"),
                        subtitle: L("Größere Dateien werden abgebrochen."),
                        icon: "arrow.down.doc",
                        tint: DS.Accent.indigo,
                        help: L("Gilt pro Verbindung (1–200 MB, Standard 25 MB).")
                    ) {
                        stepperBadge(L("\(viewModel.pythonDownloadMaxMB) MB"), value: $viewModel.pythonDownloadMaxMB, range: 1...200, step: 5)
                    }

                    SettingsHairline()

                    SettingsRow(
                        title: L("Downloads pro Python-Lauf"),
                        subtitle: L("Höchstzahl an Verbindungen, die ein Skript aufbauen darf."),
                        icon: "number",
                        tint: DS.Accent.indigo,
                        help: L("Gezählt wird jede Verbindung zu einer Domain (1–50, Standard 10).")
                    ) {
                        stepperBadge("\(viewModel.pythonMaxDownloadsPerRun)", value: $viewModel.pythonMaxDownloadsPerRun, range: 1...50)
                    }

                    SettingsHairline()

                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text(L("Erlaubte Dateitypen"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(DownloadFileType.allCases) { type in
                            Toggle(isOn: Binding(
                                get: { viewModel.pythonDownloadTypes.contains(type) },
                                set: { on in
                                    if on { if !viewModel.pythonDownloadTypes.contains(type) { viewModel.pythonDownloadTypes.append(type) } }
                                    else { viewModel.pythonDownloadTypes.removeAll { $0 == type } }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(type.label).font(.system(size: 12.5, weight: .medium, design: .rounded))
                                    Text(type.help).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }

                    SettingsHairline()

                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text(L("Immer erlaubte Domains"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: DS.Space.s) {
                            TextField(L("z. B. api.open-meteo.com"), text: $newDomain)
                                .modifier(SettingsFieldStyle())
                                .onSubmit(addDomain)
                            Button(L("Hinzufügen"), action: addDomain)
                                .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.indigo))
                                .disabled(Self.normalized(newDomain) == nil)
                        }
                        if viewModel.downloadAllowedDomains.isEmpty {
                            Text(L("Noch keine. Mit „Immer erlauben“ im Dialog landen Domains hier."))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(viewModel.downloadAllowedDomains, id: \.self) { domain in
                            HStack {
                                Image(systemName: "checkmark.shield").foregroundStyle(DS.Accent.emerald)
                                Text(domain).font(.system(size: 12.5, design: .monospaced))
                                Spacer()
                                Button {
                                    viewModel.downloadAllowedDomains.removeAll { $0 == domain }
                                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.plain)
                                .help(L("Freigabe für \(domain) entfernen"))
                                .accessibilityLabel(L("Freigabe für \(domain) entfernen"))
                            }
                        }
                    }
                }
            }
        }
    }

    private func addDomain() {
        guard let domain = Self.normalized(newDomain) else { return }
        if !viewModel.downloadAllowedDomains.contains(domain) { viewModel.downloadAllowedDomains.append(domain) }
        newDomain = ""
    }

    /// „https://www.Example.org/pfad“ → „example.org“; nil bei Ungültigem.
    static func normalized(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: text.contains("://") ? text : "https://" + text), let host = url.host { text = host }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        return text.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+$"#, options: .regularExpression) != nil ? text : nil
    }
}


/// Bibliotheken für interaktive Ausgaben: was lokal in der App liegt, und die eigene Liste immer
/// erlaubter Domains für alles andere (getrennt von den Python-Domains).
private struct HTMLLibrariesSection: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var newDomain = ""

    static let bundled = "Chart.js, D3, three.js (r128 + OrbitControls), p5.js, anime.js, GSAP, Matter.js, Alpine, Vue 3, " +
        "React 18, Cytoscape, vis-network, Leaflet, Lodash, Tailwind, Font Awesome, KaTeX, Mermaid"

    var body: some View {
        SettingsDisclosureSection(
            title: L("Erweitert (Bibliotheken für interaktive Ausgaben)"),
            subtitle: L("Lokale Bibliotheken und erlaubte Domains für HTML-Ausgaben"),
            icon: "shippingbox",
            tint: DS.Accent.indigo
        ) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("In der App enthalten"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(Self.bundled)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("Verweist eine Ausgabe auf diese Bibliotheken im Netz, nutzt die App die lokale Kopie – ohne Rückfrage, auch offline."))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsHairline()

                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(L("Immer erlaubte Domains"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: DS.Space.s) {
                        TextField(L("z. B. cdn.jsdelivr.net"), text: $newDomain)
                            .modifier(SettingsFieldStyle())
                            .onSubmit(addDomain)
                        Button(L("Hinzufügen"), action: addDomain)
                            .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.indigo))
                            .disabled(PythonInternetSection.normalized(newDomain) == nil)
                    }
                    if viewModel.htmlLibraryDomains.isEmpty {
                        Text(L("Noch keine. Andere Bibliotheken fragt die App beim ersten Laden nach (Einmal, Immer, Ablehnen). Netzabfragen aus der Ausgabe bleiben immer gesperrt."))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(viewModel.htmlLibraryDomains, id: \.self) { domain in
                        HStack {
                            Image(systemName: "checkmark.shield").foregroundStyle(DS.Accent.emerald)
                            Text(domain).font(.system(size: 12.5, design: .monospaced))
                            Spacer()
                            Button {
                                viewModel.htmlLibraryDomains.removeAll { $0 == domain }
                            } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                            .help(L("Freigabe für \(domain) entfernen"))
                            .accessibilityLabel(L("Freigabe für \(domain) entfernen"))
                        }
                    }
                }
            }
        }
    }

    private func addDomain() {
        guard let domain = PythonInternetSection.normalized(newDomain) else { return }
        if !viewModel.htmlLibraryDomains.contains(domain) { viewModel.htmlLibraryDomains.append(domain) }
        newDomain = ""
    }
}
