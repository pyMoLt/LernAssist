import Foundation
import SwiftUI
import AppKit
import Combine
import os

// Einstellungen, Erscheinungsbild, Endpunkt-Profile und Hotkeys.
extension ChatViewModel {
    // MARK: - Custom Prompts

    /// Gibt den aktiven Prompt für den gewählten Lernmodus zurück (Custom > Default)
    func prompt(for style: LearningStyle) -> String {
        let custom = customPrompts[style.rawValue] ?? ""
        return custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? style.defaultPrompt
            : custom
    }

    func currentPersistedSettings() -> PersistedSettings {
        let hkMap = Dictionary(uniqueKeysWithValues: hotkeys.map { ($0.key.rawValue, $0.value) })
        var settings = PersistedSettings(
            profiles: profiles,
            activeProfileID: activeProfileID,
            fallbackProfileID: fallbackProfileID,
            learningStyle: learningStyle.rawValue,
            customPrompts: customPrompts,
            searchEnabled: searchEnabled,
            searxngURL: searxngURL,
            maxBrowseCharacters: maxBrowseCharacters,
            maxToolRounds: maxToolRounds,
            keepMultipleImagesInHistory: keepMultipleImagesInHistory,
            hotkeys: hkMap,
            toolStates: ToolRegistry.shared.enabledStates(),
            autoLabelingEnabled: autoLabelingEnabled,
            autoImageToTextEnabled: autoImageToTextEnabled,
            imageExtractionDetail: imageExtractionDetail,
            extractImagesFromPDF: extractImagesFromPDF,
            appTheme: appTheme,
            chatFontSize: chatFontSize,
            isMenuBarApp: isMenuBarApp,
            disableThinkingForBackgroundJobs: disableThinkingForBackgroundJobs,
            showMenuBarIcon: showMenuBarIcon,
            autoCompactSuggestionsEnabled: autoCompactSuggestionsEnabled,
            autoCompactThreshold: autoCompactThreshold,
            compactSummaryTokens: compactSummaryTokens,
            compactKeepLastMessages: compactKeepLastMessages,
            youtubeSubtitleLanguage: youtubeSubtitleLanguage,
            youtubeTranscriptCharLimit: youtubeTranscriptCharLimit,
            customArchiveFolders: customArchiveFolders
        )
        settings.research = research
        settings.autoInstallPythonPackages = autoInstallPythonPackages
        settings.autoArchiveDays = autoArchiveDays
        settings.preserveThinking = preserveThinking
        settings.quizDifficulty = quizDifficulty
        settings.flashcardDifficulty = flashcardDifficulty
        settings.pythonDownloadMaxMB = pythonDownloadMaxMB
        settings.downloadAllowedDomains = downloadAllowedDomains
        settings.htmlLibraryDomains = htmlLibraryDomains
        settings.appearance = appearance
        settings.appLanguage = appLanguage
        settings.modelSettings = modelSettings
        settings.modelSettingsMigrated = true
        settings.searxngServers = searxngServers
        settings.activeSearXNGServerID = activeSearXNGServerID
        settings.connectionWatchEnabled = connectionWatchEnabled
        settings.connectionWatchSystemNotices = connectionWatchSystemNotices
        settings.pythonInternetEnabled = pythonInternetEnabled
        settings.pythonMaxDownloadsPerRun = pythonMaxDownloadsPerRun
        settings.pythonDownloadTypes = pythonDownloadTypes
        settings.flashcardRetention = flashcardRetention
        settings.setupCompleted = setupCompleted
        settings.pythonSandboxTimeout = pythonSandboxTimeout
        settings.pythonMaxOutputCharacters = pythonMaxOutputCharacters
        settings.pythonMaxScriptVersions = pythonMaxScriptVersions
        settings.pythonPlotDpi = pythonPlotDpi
        settings.documentCacheDuration = documentCacheDuration
        settings.flashcardAgainDelayMinutes = flashcardAgainDelayMinutes
        settings.flashcardCardsPerResponse = flashcardCardsPerResponse
        settings.titleRefinementTurns = titleRefinementTurns
        settings.documentImageBudget = documentImageBudget
        settings.inlineExplainRadius = inlineExplainRadius
        return settings
    }

    func saveSettings() {
        SettingsStore.shared.save(currentPersistedSettings())
    }

    /// Einmalig (Version 4.0): Denken an/aus, Budget und Preserve Thinking hängen jetzt am Modell –
    /// bisherige Werte aus den Profilen und der globalen Einstellung werden übernommen.
    static func migratedModelSettings(from s: PersistedSettings) -> [String: ModelSettings] {
        var models = s.modelSettings
        guard !s.modelSettingsMigrated else { return models }
        for profile in s.profiles where !profile.model.isEmpty {
            let key = ModelSettings.key(for: profile.model)
            var entry = models[key] ?? ModelSettings()
            if profile.thinkingMode != .serverDefault, entry.thinking == nil { entry.thinking = profile.thinkingMode }
            if let budget = profile.thinkingBudget, entry.thinkingBudget == nil { entry.thinkingBudget = budget }
            if !s.preserveThinking, entry.preserveThinking == nil { entry.preserveThinking = false }
            if !entry.isEmpty { models[key] = entry }
        }
        return models
    }

    func loadSettings() {
        let s = SettingsStore.shared.load()
        customPrompts = LearningStyle.migratedFromLegacyPrompts(s.customPrompts)
        profiles = s.profiles
        activeProfileID = s.activeProfileID ?? s.profiles.first?.id
        fallbackProfileID = s.fallbackProfileID
        if let style = LearningStyle(rawValue: s.learningStyle) {
            learningStyle = style
        }
        searchEnabled = s.searchEnabled
        let catalog = Self.searxngCatalog(from: s)
        searxngServers = catalog.servers
        activeSearXNGServerID = catalog.activeID
        searxngURL = catalog.servers.first(where: { $0.id == catalog.activeID })?.url ?? s.searxngURL
        connectionWatchEnabled = s.connectionWatchEnabled
        connectionWatchSystemNotices = s.connectionWatchSystemNotices
        maxBrowseCharacters = s.maxBrowseCharacters
        maxToolRounds = min(max(s.maxToolRounds, 1), 25)
        keepMultipleImagesInHistory = s.keepMultipleImagesInHistory
        // Hotkeys: gespeicherte Werte, mit Default-Fallback je fehlender Aktion
        var loaded: [HotkeyAction: Hotkey] = Dictionary(
            uniqueKeysWithValues: Hotkey.defaultMap.map { ($0.key, $0.value) }
        )
        for (rawValue, hk) in s.hotkeys {
            if let action = HotkeyAction(rawValue: rawValue) { loaded[action] = hk }
        }
        // Migration: Installationen von vor dem Default-Fix (siehe HotkeyAction.defaultMap) hatten
        // .screenshot und .toggleWindow noch auf denselben Hotkey (⌘⇧L) gemappt – macOS feuert dann
        // pro Tastendruck zwei separate Carbon-Events, wodurch z.B. reines Fenster-Ausblenden
        // zusätzlich einen ungewollten interaktiven Screenshot auslöste. Der defaultMap-Fix selbst
        // zieht bei bereits gespeicherten settings.json-Werten nicht automatisch nach – hier
        // einmalig bereinigen, falls die Kollision noch besteht.
        var hotkeysMigrated = false
        if loaded[.screenshot] == loaded[.toggleWindow], let fixedDefault = Hotkey.defaultMap[.screenshot] {
            loaded[.screenshot] = fixedDefault
            hotkeysMigrated = true
        }
        hotkeys = loaded
        // Tool-Zustände laden
        if !s.toolStates.isEmpty {
            ToolRegistry.shared.loadEnabledStates(from: s.toolStates)
        }
        autoLabelingEnabled = s.autoLabelingEnabled
        autoImageToTextEnabled = s.autoImageToTextEnabled
        extractImagesFromPDF = s.extractImagesFromPDF
        imageExtractionDetail = s.imageExtractionDetail
        appTheme = s.appTheme
        chatFontSize = s.chatFontSize
        isMenuBarApp = s.isMenuBarApp
        disableThinkingForBackgroundJobs = s.disableThinkingForBackgroundJobs
        autoCompactSuggestionsEnabled = s.autoCompactSuggestionsEnabled
        autoCompactThreshold = s.autoCompactThreshold
        compactSummaryTokens = s.compactSummaryTokens
        compactKeepLastMessages = s.compactKeepLastMessages
        research = s.research
        autoInstallPythonPackages = s.autoInstallPythonPackages
        youtubeSubtitleLanguage = s.youtubeSubtitleLanguage
        youtubeTranscriptCharLimit = s.youtubeTranscriptCharLimit
        customArchiveFolders = s.customArchiveFolders
        showMenuBarIcon = s.showMenuBarIcon
        autoArchiveDays = s.autoArchiveDays
        preserveThinking = s.preserveThinking
        quizDifficulty = s.quizDifficulty
        flashcardDifficulty = s.flashcardDifficulty
        pythonDownloadMaxMB = s.pythonDownloadMaxMB
        downloadAllowedDomains = s.downloadAllowedDomains
        htmlLibraryDomains = s.htmlLibraryDomains
        appearance = s.appearance
        appLanguage = s.appLanguage
        modelSettings = Self.migratedModelSettings(from: s)
        pythonInternetEnabled = s.pythonInternetEnabled
        pythonMaxDownloadsPerRun = s.pythonMaxDownloadsPerRun
        pythonDownloadTypes = s.pythonDownloadTypes
        ToolRegistry.shared.quizDifficulty = s.quizDifficulty
        flashcardRetention = s.flashcardRetention
        setupCompleted = s.setupCompleted
        pythonSandboxTimeout = s.pythonSandboxTimeout
        pythonMaxOutputCharacters = s.pythonMaxOutputCharacters
        pythonMaxScriptVersions = s.pythonMaxScriptVersions
        pythonPlotDpi = s.pythonPlotDpi
        documentCacheDuration = s.documentCacheDuration
        flashcardAgainDelayMinutes = s.flashcardAgainDelayMinutes
        flashcardCardsPerResponse = s.flashcardCardsPerResponse
        titleRefinementTurns = s.titleRefinementTurns
        documentImageBudget = s.documentImageBudget
        inlineExplainRadius = s.inlineExplainRadius
        CodingEnvironment.shared.limits = CodingEnvironment.Limits(
            maxScriptVersions: s.pythonMaxScriptVersions, maxOutputCharacters: s.pythonMaxOutputCharacters,
            sandboxTimeout: s.pythonSandboxTimeout, plotDpi: s.pythonPlotDpi,
            internetEnabled: s.pythonInternetEnabled, downloadMaxMB: s.pythonDownloadMaxMB,
            maxDownloadsPerRun: s.pythonMaxDownloadsPerRun, downloadTypes: s.pythonDownloadTypes)
        DocumentCache.defaultDuration = s.documentCacheDuration

        if hotkeysMigrated { saveSettings() }
    }

    // MARK: - Erscheinungsbild

    /// Setzt `NSApp.appearance` passend zu `appTheme`. Das war vorher ein reiner UI-Stub:
    /// die Einstellung wurde persistiert, aber nirgends tatsächlich angewendet (beobachteter
    /// Dark-Mode-Bug: Auswahl in den Settings hatte keinerlei Effekt).
    /// App-weit statt pro View gesetzt, damit es automatisch auch für die WKWebViews
    /// (Markdown-Rendering, HTML-Tool-Artefakte) greift – deren CSS `prefers-color-scheme`
    /// richtet sich nach der effektiven NSAppearance des Fensters, nicht nach SwiftUI-State.
    func applyAppTheme(_ theme: String? = nil) {
        switch theme ?? appTheme {
        case "Light": NSApp.appearance = NSAppearance(named: .aqua)
        case "Dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil // System folgen
        }
    }

    // MARK: - Kontextfenster automatisch abfragen

    /// Fragt für das aktive Profil `GET /v1/models` (oder `/api/v0/models`) ab und übernimmt die
    /// gemeldete Kontextfenster-Größe für das aktuell gewählte Modell – automatisch, ohne dass der
    /// Nutzer dafür in die Settings gehen und das Modell manuell neu auswählen muss. War vorher der
    /// Grund, warum die MetricsBar immer die feste 8192-Fallback-Größe zeigte: `contextSizeOverride`
    /// wurde ausschließlich gesetzt, wenn man in ModelTabView "Modelle laden" klickte UND danach
    /// das Modell erneut aus der Liste auswählte.
    /// Setzt NICHTS, wenn bereits ein `contextSizeOverride` vorhanden ist (manuell gesetzter Wert
    /// hat Vorrang) oder der Server die Kontextgröße nicht meldet.
    func refreshContextWindowForActiveProfile() {
        guard let profile = activeProfile else { return }
        let profileId = profile.id
        Task { [weak self] in
            var models = (try? await EndpointManager.fetchProviderModels(for: profile)) ?? []
            if profile.provider == .omlx, !models.contains(where: { $0.id == profile.model && $0.contextWindow != nil }) {
                let extra = await EndpointDiagnostics.omlxStatus(profile)
                for m in extra where !models.contains(where: { $0.id == m.id }) {
                    models.append(m)
                }
            }
            let fetchedModels = models
            await MainActor.run {
                guard let self else { return }
                if !fetchedModels.isEmpty {
                    self.cachedModelsByProfile[profileId] = fetchedModels.map { (id: $0.id, contextWindow: $0.contextWindow) }
                }
                guard let idx = self.profiles.firstIndex(where: { $0.id == profileId }),
                      self.profiles[idx].contextSizeOverride == nil,
                      let match = fetchedModels.first(where: { $0.id == profile.model && $0.contextWindow != nil }),
                      let ctx = match.contextWindow
                else { return }
                self.profiles[idx].contextSizeOverride = ctx
                self.saveSettings()
            }
        }
    }

    @discardableResult
    func loadModelsForProfile(_ profile: EndpointProfile) async -> [(id: String, contextWindow: Int?)] {
        let models = (try? await EndpointManager.fetchModels(for: profile)) ?? []
        await MainActor.run {
            if !models.isEmpty {
                self.cachedModelsByProfile[profile.id] = models
            }
        }
        return models
    }

    // MARK: - Endpunkt-Profile: CRUD

    /// Testet, ob die konfigurierte SearXNG-Instanz erreichbar ist und tatsächlich JSON-
    /// Suchergebnisse liefert (nicht nur, dass der Port offen ist) – dieselbe Anfrageform wie
    /// `SearchService.searxng(...)`, aber bewusst OHNE DDG-Fallback, damit ein Ping die echte
    /// SearXNG-Erreichbarkeit prüft statt durch den Fallback maskiert zu werden.
    enum SearXNGPingResult: Equatable {
        case ok
        case nothingListening
        case timeout
        case httpStatus(Int)
        case notSearXNG
        case invalidURL

        /// Ursachengerechte Diagnose statt nacktem Fehler ✗ (SearXNG-Bug): Der Nutzer sieht
        /// jetzt WAS kaputt ist (nichts lauscht auf dem Port / JSON-API deaktiviert / …) und
        /// was er konkret tun kann.
        var diagnostic: String {
            switch self {
            case .ok:
                return "✓ SearXNG erreichbar – JSON-Suche funktioniert."
            case .nothingListening:
                return "✗ Auf dieser Adresse/Port lauscht nichts (Verbindung verweigert). Prüfe mit „docker ps“ das Port-Mapping deines Containers. Auf dem Rechner, auf dem der Container läuft, ist es http://127.0.0.1:8082. Von einem anderen Gerät aus muss der Hostname oder die IP dieses Rechners mit :8082 eingetragen werden (z. B. über ein VPN wie Tailscale) – localhost zeigt dort nur auf das eigene Gerät."
            case .timeout:
                return "✗ Keine Antwort innerhalb von 8 s. Ist das Gerät hinter der Adresse an und erreichbar (eine veraltete Tailscale-Adresse schweigt einfach)? Läuft der Container (docker ps)?"
            case .httpStatus(let code) where code == 401:
                return "✗ HTTP 401: Der Server verlangt eine Anmeldung. Beim Such-Server die Anmeldung (z. B. Bearer-Token) eintragen bzw. prüfen."
            case .httpStatus(let code) where code == 429:
                return "✗ HTTP 429: SearXNG begrenzt die Anfragen (Limiter). Bei einer privaten Instanz hinter einem Proxy in der settings.yml „limiter: false“ setzen oder den Proxy als vertrauenswürdig eintragen."
            case .httpStatus(let code) where code == 403 || code == 410:
                return "✗ SearXNG antwortet mit HTTP \(code): Entweder fehlt die Anmeldung, oder die JSON-API ist serverseitig deaktiviert. In der SearXNG-settings.yml unter search → formats „json“ ergänzen und den Container neu starten."
            case .httpStatus(let code):
                return "✗ SearXNG antwortet mit HTTP \(code) – ungewöhnlich. Instanz-Logs prüfen (docker logs <Container>)."
            case .notSearXNG:
                return "✗ Es antwortet ein Server, aber keine SearXNG-JSON-Suche. Ist die URL die Basis-Instanz (z.B. http://127.0.0.1:8082) und nicht versehentlich ein anderer Dienst?"
            case .invalidURL:
                return "✗ Ungültige URL – erwartetes Format: http://127.0.0.1:8082"
            }
        }
    }

    /// Katalog aus den gespeicherten Einstellungen; ältere Einstellungen mit nur einer Adresse
    /// bekommen einen Eintrag „Lokal“ bzw. „Remote“.
    static func searxngCatalog(from s: PersistedSettings) -> (servers: [SearXNGServer], activeID: UUID?) {
        var servers = s.searxngServers
        let url = s.searxngURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if servers.isEmpty, !url.isEmpty { servers = [SearXNGServer.migrated(from: url)] }
        let active = servers.first(where: { $0.id == s.activeSearXNGServerID }) ?? servers.first
        return (servers, active?.id)
    }

    var activeSearXNGServer: SearXNGServer? {
        searxngServers.first { $0.id == activeSearXNGServerID }
    }

    /// Anmelde-Header eines Such-Servers (Geheimnis aus dem Schlüsselbund).
    func searxngHeaders(for server: SearXNGServer?) -> [String: String] {
        guard let server, server.auth != .none else { return [:] }
        return server.authHeaders(secret: KeychainStore.secret(account: server.keychainAccount))
    }

    func selectSearXNGServer(_ id: UUID) {
        guard let server = searxngServers.first(where: { $0.id == id }) else { return }
        activeSearXNGServerID = id
        searxngURL = server.url
        syncToolRegistry()
    }

    /// Eintrag ändern oder hinzufügen; beim aktiven Eintrag gelten Adresse und Anmeldung sofort.
    func saveSearXNGServer(_ server: SearXNGServer, secret: String?) {
        if let index = searxngServers.firstIndex(where: { $0.id == server.id }) {
            searxngServers[index] = server
        } else {
            searxngServers.append(server)
        }
        if let secret { KeychainStore.setSecret(secret, account: server.keychainAccount) }
        if activeSearXNGServerID == nil { activeSearXNGServerID = server.id }
        if server.id == activeSearXNGServerID, searxngURL != server.url { searxngURL = server.url }
        syncToolRegistry()
    }

    func deleteSearXNGServer(_ id: UUID) {
        guard let server = searxngServers.first(where: { $0.id == id }) else { return }
        KeychainStore.setSecret("", account: server.keychainAccount)
        searxngServers.removeAll { $0.id == id }
        if activeSearXNGServerID == id {
            activeSearXNGServerID = searxngServers.first?.id
            searxngURL = searxngServers.first?.url ?? ""
        }
        syncToolRegistry()
    }

    func testSearxngConnection(baseURL: String, headers: [String: String] = [:]) async -> SearXNGPingResult {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return .invalidURL }
        if !base.lowercased().hasPrefix("http") { base = "http://" + base }
        while base.hasSuffix("/") { base = String(base.dropLast()) }

        var components = URLComponents(string: base + "/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: "ping"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components?.url else { return .invalidURL }

        var request = URLRequest(url: url, timeoutInterval: 8.0)
        request.setValue("LernAssist/1.0", forHTTPHeaderField: "User-Agent")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .notSearXNG }
            guard http.statusCode == 200 else { return .httpStatus(http.statusCode) }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["results"] != nil else { return .notSearXNG }
            return .ok
        } catch let urlError as URLError {
            switch urlError.code {
            case .timedOut: return .timeout
            default: return .nothingListening
            }
        } catch {
            return .nothingListening
        }
    }

    func testConnection(profile: EndpointProfile) async -> Bool {
        await diagnoseConnection(profile: profile).isOK
    }

    /// Verbindungstest mit verständlicher Meldung (Server aus / Key fehlt / Modell unbekannt …).
    /// Lädt bei erreichbarem Server zugleich die verfügbaren Modelle in `cachedModelsByProfile`.
    func diagnoseConnection(profile: EndpointProfile) async -> ConnectionDiagnosis {
        let diag = await EndpointDiagnostics.diagnose(profile)
        if let models = try? await EndpointManager.fetchModels(for: profile), !models.isEmpty {
            await MainActor.run {
                self.cachedModelsByProfile[profile.id] = models
            }
        }
        return diag
    }

    func addProfile(_ profile: EndpointProfile, makeActive: Bool = true) {
        profiles.append(profile)
        if makeActive { activeProfileID = profile.id }
        saveSettings() // strukturelle Änderungen sofort persistieren
    }

    func deleteProfile(id: UUID) {
        guard profiles.count > 1 else { return } // immer mindestens ein Profil behalten
        profiles.removeAll(where: { $0.id == id })
        if fallbackProfileID == id { fallbackProfileID = nil }
        if activeProfileID == id { activeProfileID = profiles.first?.id }
        KeychainStore.deleteAPIKey(forProfileID: id) // Keychain-Eintrag mit entfernen (Audit P1)
        saveSettings() // strukturelle Änderungen sofort persistieren
    }

    /// Hotkey für eine Aktion aktualisieren, speichern und AppDelegate benachrichtigen.
    func updateHotkey(_ hotkey: Hotkey, for action: HotkeyAction) {
        hotkeys[action] = hotkey
        saveSettings()
        NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
    }


    // MARK: - Standardwerte wiederherstellen

    /// Setzt nur technische Parameter (Grenzwerte, Timeouts, Budgets) auf die Standardwerte.
    /// Bleibt UNVERÄNDERT: Endpunkte und Profile samt Modell und Sampling-Werten, API-Keys,
    /// eigene Prompts, Lernstil, Darstellung, Hotkeys, Ein/Aus-Schalter, Tool-Auswahl sowie die
    /// Recherche-Quellen, Domainlisten, Sprachen und die Kontakt-E-Mail.
    func resetToDefaults() {
        let d = PersistedSettings.defaults
        maxBrowseCharacters = d.maxBrowseCharacters
        maxToolRounds = d.maxToolRounds
        autoCompactThreshold = d.autoCompactThreshold
        compactSummaryTokens = d.compactSummaryTokens
        compactKeepLastMessages = d.compactKeepLastMessages
        youtubeTranscriptCharLimit = d.youtubeTranscriptCharLimit
        flashcardRetention = d.flashcardRetention
        pythonSandboxTimeout = d.pythonSandboxTimeout
        pythonMaxOutputCharacters = d.pythonMaxOutputCharacters
        pythonMaxScriptVersions = d.pythonMaxScriptVersions
        pythonPlotDpi = d.pythonPlotDpi
        pythonDownloadMaxMB = d.pythonDownloadMaxMB
        pythonMaxDownloadsPerRun = d.pythonMaxDownloadsPerRun
        documentCacheDuration = d.documentCacheDuration
        flashcardAgainDelayMinutes = d.flashcardAgainDelayMinutes
        flashcardCardsPerResponse = d.flashcardCardsPerResponse
        titleRefinementTurns = d.titleRefinementTurns
        documentImageBudget = d.documentImageBudget
        inlineExplainRadius = d.inlineExplainRadius
        research = Self.researchWithDefaultLimits(research)

        syncToolRegistry()
        syncResearchConfiguration()
        saveSettings()
    }

    /// Recherche: nur Mengen, Budgets und Timeouts zurück – Quellen, Reranker-Auswahl, Sprachen,
    /// Domainlisten und Kontakt-E-Mail bleiben.
    static func researchWithDefaultLimits(_ current: ResearchSettings) -> ResearchSettings {
        let d = ResearchSettings()
        var r = current
        r.resultsPerSource = d.resultsPerSource
        r.fullTextPages = d.fullTextPages
        r.fetchTimeout = d.fetchTimeout
        r.maxDownloadMB = d.maxDownloadMB
        r.passageChars = d.passageChars
        r.maxPassages = d.maxPassages
        r.maxPassagesPerSource = d.maxPassagesPerSource
        r.tokenBudget = d.tokenBudget
        r.rerankerTimeout = d.rerankerTimeout
        r.rerankerWindow = d.rerankerWindow
        r.exaMinWebResults = d.exaMinWebResults
        r.exaResults = d.exaResults
        r.cacheMinutes = d.cacheMinutes
        return r
    }

    var activeSession: ChatSession? {
        sessions.first(where: { $0.id == activeSessionId })
    }
}
