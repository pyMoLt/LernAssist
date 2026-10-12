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
            isSemanticSearchEnabled: isSemanticSearchEnabled,
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
        return settings
    }

    func saveSettings() {
        SettingsStore.shared.save(currentPersistedSettings())
    }

    func loadSettings() {
        let s = SettingsStore.shared.load()
        customPrompts = s.customPrompts
        profiles = s.profiles
        activeProfileID = s.activeProfileID ?? s.profiles.first?.id
        fallbackProfileID = s.fallbackProfileID
        if let style = LearningStyle(rawValue: s.learningStyle) {
            learningStyle = style
        }
        searchEnabled = s.searchEnabled
        searxngURL = s.searxngURL
        maxBrowseCharacters = s.maxBrowseCharacters
        maxToolRounds = min(max(s.maxToolRounds, 1), 12)
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
        isSemanticSearchEnabled = s.isSemanticSearchEnabled
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

        if hotkeysMigrated { saveSettings() }
    }

    // MARK: - Erscheinungsbild

    /// Setzt `NSApp.appearance` passend zu `appTheme`. Das war vorher ein reiner UI-Stub:
    /// die Einstellung wurde persistiert, aber nirgends tatsächlich angewendet (beobachteter
    /// Dark-Mode-Bug: Auswahl in den Settings hatte keinerlei Effekt).
    /// App-weit statt pro View gesetzt, damit es automatisch auch für die WKWebViews
    /// (Markdown-Rendering, HTML-Tool-Artefakte) greift – deren CSS `prefers-color-scheme`
    /// richtet sich nach der effektiven NSAppearance des Fensters, nicht nach SwiftUI-State.
    func applyAppTheme() {
        switch appTheme {
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
        guard let profile = activeProfile, profile.contextSizeOverride == nil else { return }
        let profileId = profile.id
        Task { [weak self] in
            var models = (try? await EndpointManager.fetchProviderModels(for: profile)) ?? []
            if profile.provider == .omlx, !models.contains(where: { $0.id == profile.model && $0.contextWindow != nil }) {
                models += await EndpointDiagnostics.omlxStatus(profile)
            }
            guard let match = models.first(where: { $0.id == profile.model && $0.contextWindow != nil }),
                  let ctx = match.contextWindow else { return }
            await MainActor.run {
                guard let self,
                      let idx = self.profiles.firstIndex(where: { $0.id == profileId }),
                      self.profiles[idx].contextSizeOverride == nil // in der Zwischenzeit nicht manuell überschrieben
                else { return }
                self.profiles[idx].contextSizeOverride = ctx
                self.saveSettings()
            }
        }
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
                return "✗ Auf dieser Adresse/Port lauscht nichts (Verbindung verweigert). Prüfe mit „docker ps“ das Port-Mapping deines Containers. Für den Docker-Mac ist es hier http://127.0.0.1:8082. Von einem anderen Mac muss die Tailscale-Adresse des Docker-Macs mit :8082 eingetragen werden – localhost zeigt dort nur auf den eigenen Mac."
            case .timeout:
                return "✗ Adresse spricht an, antwortet aber nicht innerhalb von 8 s. Läuft der Container wirklich (docker ps) und ist er healthy?"
            case .httpStatus(let code) where code == 403 || code == 410:
                return "✗ SearXNG antwortet mit HTTP \(code): Die JSON-API ist serverseitig deaktiviert. In der SearXNG-settings.yml unter search → formats „json“ ergänzen und den Container neu starten."
            case .httpStatus(let code):
                return "✗ SearXNG antwortet mit HTTP \(code) – ungewöhnlich. Instanz-Logs prüfen (docker logs <Container>)."
            case .notSearXNG:
                return "✗ Es antwortet ein Server, aber keine SearXNG-JSON-Suche. Ist die URL die Basis-Instanz (z.B. http://127.0.0.1:8082) und nicht versehentlich ein anderer Dienst?"
            case .invalidURL:
                return "✗ Ungültige URL – erwartetes Format: http://127.0.0.1:8082"
            }
        }
    }

    func testSearxngConnection(baseURL: String) async -> SearXNGPingResult {
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
    func diagnoseConnection(profile: EndpointProfile) async -> ConnectionDiagnosis {
        await EndpointDiagnostics.diagnose(profile)
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

    var activeSession: ChatSession? {
        sessions.first(where: { $0.id == activeSessionId })
    }
}
