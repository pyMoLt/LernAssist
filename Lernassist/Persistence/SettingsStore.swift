import Foundation
import os

/// Alle persistierten App-Einstellungen. Wird 1:1 nach `settings.json` gespiegelt.
///
/// Der Custom-Decoder erlaubt einen nahtlosen Übergang vom Phase-2-Flachformat
/// (einzelnes `apiEndpoint`/`apiKey`/`modelName`) auf mehrere Endpunkt-Profile (Phase 3):
/// Findet er kein `profiles`-Array, synthetisiert er daraus ein einzelnes "Lokal"-Profil.
struct PersistedSettings: Codable {
    var profiles: [EndpointProfile]
    var activeProfileID: UUID?
    var fallbackProfileID: UUID?
    var learningStyle: String
    var customPrompts: [String: String]
    var searchEnabled: Bool
    var searxngURL: String
    var maxBrowseCharacters: Int
    /// Maximale aufeinanderfolgende Tool-Runden eines Modell-Turns (1...12, Standard 8).
    var maxToolRounds: Int
    /// Wenn true, werden alle Bilder im bisherigen Gesprächsverlauf erneut an das Modell
    /// mitgeschickt (nicht nur das jeweils neueste) – kostet mehr Kontext/Tokens, erlaubt aber
    /// Rückfragen zu älteren Screenshots. Default aus, um Token-Budget bei kleinen Modellen zu schonen.
    var keepMultipleImagesInHistory: Bool
    /// Belegbare Tastenkombinationen je Aktion (rawValue-String → Hotkey).
    var hotkeys: [String: Hotkey]
    /// 2 = Hotkey-Defaults vom 12.10.2026 (⌃⇧ statt ⌘-Kürzeln) sind angewendet.
    var hotkeyDefaultsVersion: Int = 2
    /// Tool-Registry-Zustände: toolName → isEnabled.
    var toolStates: [String: Bool]
    /// Phase 7C: Hintergrund-Aufgaben
    var autoLabelingEnabled: Bool
    var autoImageToTextEnabled: Bool
    /// Best-effort "Thinking" für Hintergrund-Jobs (Titel/Bild-Beschreibung/Zusammenfassung)
    /// abschalten – injiziert chat_template_kwargs.enable_thinking=false, Ollamas think=false und
    /// den "/no_think"-Texttag gleichzeitig, da je nach Server/Modell nur einer davon greift.
    var disableThinkingForBackgroundJobs: Bool
    /// Phase 8: RAG/Semantische Suche (Experimentell)
    var isSemanticSearchEnabled: Bool
    /// Phase 7G: Detailgrad der Bildextraktion aus PDFs (z.B. "Kurz", "Normal", "Detailliert")
    var imageExtractionDetail: String
    /// Steuert, ob beim Hochladen von PDFs jede Seite an das Vision-Modell gesendet wird, um Bilder zu beschreiben
    var extractImagesFromPDF: Bool
    /// Phase 9+: UI Customizations & Menu Bar
    var appTheme: String
    /// Schriftgrößen-Multiplikator für den Chat-Inhalt (0.8...1.5, stufenlos per Slider einstellbar
    /// statt der früheren Klein/Mittel/Groß-Auswahl). 1.0 = Standardgröße.
    var chatFontSize: Double
    var isMenuBarApp: Bool
    /// Unabhängig von isMenuBarApp (Dock-Icon aus): steuert nur, ob zusätzlich ein Symbol in der
    /// Menüleiste erscheint. Beide lassen sich frei kombinieren.
    var showMenuBarIcon: Bool
    // Phase H – konfigurierbare Werte der neuen Features:
    /// Auto-Kompakt-Angebot: zeigt den „Zusammenfassen"-Chip, wenn der Chat den Kontext füllt.
    var autoCompactSuggestionsEnabled: Bool
    /// Schwellwert (0...1) des geschätzten Kontext-Füllstands, ab dem das Angebot erscheint.
    var autoCompactThreshold: Double
    /// Zielgröße der /compact-Zusammenfassung in Tokens.
    var compactSummaryTokens: Int
    /// So viele letzte Nachrichten werden wörtlich an die Zusammenfassung angehängt.
    var compactKeepLastMessages: Int
    /// Websuche/Recherche (Quellen, Reranker, Budgets, Domains).
    var research: ResearchSettings = ResearchSettings()
    /// coding_sandbox: Python-Pakete ohne Rückfrage installieren.
    var autoInstallPythonPackages: Bool = false
    /// Bevorzugte Untertitel-Sprache für den YouTube-Import (BCP-47-Kurzcode, z.B. "de").
    /// Leer = erste verfügbare Spur.
    var youtubeSubtitleLanguage: String
    /// Maximale Zeichen, die ein importiertes YouTube-Transkript in den Chat-Kontext einbringt.
    var youtubeTranscriptCharLimit: Int
    /// Selbst angelegte Archiv-Ordner (Namen + Reihenfolge). Persistiert, damit leere Ordner und
    /// die manuelle Sortierung einen App-Neustart überleben (Persistenz-Audit: war vorher rein
    /// in-memory; Ordner tauchten nach Neustart nur rekonstruiert aus Sessions auf, leere
    /// Ordner und ihre Position gingen verloren).
    var customArchiveFolders: [String]

    static let defaults: PersistedSettings = {
        let local = EndpointProfile(name: "Lokal", baseURL: "http://127.0.0.1:1234", model: "local-model", isRemote: false)
        let defaultHotkeys = Dictionary(
            uniqueKeysWithValues: Hotkey.defaultMap.map { ($0.key.rawValue, $0.value) }
        )
        return PersistedSettings(
            profiles: [local],
            activeProfileID: local.id,
            fallbackProfileID: nil,
            learningStyle: LearningStyle.beginner.rawValue,
            customPrompts: [:],
            searchEnabled: false,
            searxngURL: "http://127.0.0.1:8082",
            maxBrowseCharacters: 10000,
            maxToolRounds: 8,
            keepMultipleImagesInHistory: false,
            hotkeys: defaultHotkeys,
            toolStates: [:],
            autoLabelingEnabled: true,
            autoImageToTextEnabled: true,
            isSemanticSearchEnabled: false,
            imageExtractionDetail: "Normal",
            extractImagesFromPDF: true,
            appTheme: "System",
            chatFontSize: 1.0,
            isMenuBarApp: false,
            disableThinkingForBackgroundJobs: false,
            showMenuBarIcon: false,
            autoCompactSuggestionsEnabled: true,
            autoCompactThreshold: 0.75,
            compactSummaryTokens: 6_000,
            compactKeepLastMessages: 2,
            youtubeSubtitleLanguage: "de",
            youtubeTranscriptCharLimit: 30_000,
            customArchiveFolders: []
        )
    }()

    init(
        profiles: [EndpointProfile],
        activeProfileID: UUID?,
        fallbackProfileID: UUID?,
        learningStyle: String,
        customPrompts: [String: String],
        searchEnabled: Bool,
        searxngURL: String,
        maxBrowseCharacters: Int,
        maxToolRounds: Int = 8,
        keepMultipleImagesInHistory: Bool,
        hotkeys: [String: Hotkey] = [:],
        toolStates: [String: Bool] = [:],
        autoLabelingEnabled: Bool = true,
        autoImageToTextEnabled: Bool = true,
        isSemanticSearchEnabled: Bool = false,
        imageExtractionDetail: String = "Normal",
        extractImagesFromPDF: Bool = true,
        appTheme: String = "System",
        chatFontSize: Double = 1.0,
        isMenuBarApp: Bool = false,
        disableThinkingForBackgroundJobs: Bool = false,
        showMenuBarIcon: Bool = false,
        autoCompactSuggestionsEnabled: Bool = true,
        autoCompactThreshold: Double = 0.75,
        compactSummaryTokens: Int = 6_000,
        compactKeepLastMessages: Int = 2,
        youtubeSubtitleLanguage: String = "de",
        youtubeTranscriptCharLimit: Int = 30_000,
        customArchiveFolders: [String] = []
    ) {
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.fallbackProfileID = fallbackProfileID
        self.learningStyle = learningStyle
        self.customPrompts = customPrompts
        self.searchEnabled = searchEnabled
        self.searxngURL = searxngURL
        self.maxBrowseCharacters = maxBrowseCharacters
        self.maxToolRounds = min(max(maxToolRounds, 1), 12)
        self.keepMultipleImagesInHistory = keepMultipleImagesInHistory
        self.hotkeys = hotkeys
        self.toolStates = toolStates
        self.autoLabelingEnabled = autoLabelingEnabled
        self.autoImageToTextEnabled = autoImageToTextEnabled
        self.isSemanticSearchEnabled = isSemanticSearchEnabled
        self.imageExtractionDetail = imageExtractionDetail
        self.extractImagesFromPDF = extractImagesFromPDF
        self.appTheme = appTheme
        self.chatFontSize = chatFontSize
        self.isMenuBarApp = isMenuBarApp
        self.disableThinkingForBackgroundJobs = disableThinkingForBackgroundJobs
        self.showMenuBarIcon = showMenuBarIcon
        self.autoCompactSuggestionsEnabled = autoCompactSuggestionsEnabled
        self.autoCompactThreshold = autoCompactThreshold
        self.compactSummaryTokens = compactSummaryTokens
        self.compactKeepLastMessages = compactKeepLastMessages
        self.youtubeSubtitleLanguage = youtubeSubtitleLanguage
        self.youtubeTranscriptCharLimit = youtubeTranscriptCharLimit
        self.customArchiveFolders = customArchiveFolders
    }

    private enum CodingKeys: String, CodingKey {
        case profiles, activeProfileID, fallbackProfileID
        case learningStyle, customPrompts, searchEnabled, searxngURL, maxBrowseCharacters, maxToolRounds
        case keepMultipleImagesInHistory, hotkeys, toolStates, hotkeyDefaultsVersion
        case autoLabelingEnabled, autoImageToTextEnabled
        case isSemanticSearchEnabled, imageExtractionDetail, extractImagesFromPDF
        case appTheme, chatFontSize, isMenuBarApp, disableThinkingForBackgroundJobs, showMenuBarIcon
        // Phase H – konfigurierbare Werte der neuen Features:
        case autoCompactSuggestionsEnabled, autoCompactThreshold, youtubeSubtitleLanguage, youtubeTranscriptCharLimit
        case compactSummaryTokens, compactKeepLastMessages, research, autoInstallPythonPackages
        case customArchiveFolders
        // Legacy (Phase-2-Flachformat):
        case legacyApiEndpoint = "apiEndpoint"
        case legacyApiKey = "apiKey"
        case legacyModelName = "modelName"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        learningStyle = try c.decodeIfPresent(String.self, forKey: .learningStyle) ?? PersistedSettings.defaults.learningStyle
        customPrompts = try c.decodeIfPresent([String: String].self, forKey: .customPrompts) ?? [:]
        searchEnabled = try c.decodeIfPresent(Bool.self, forKey: .searchEnabled) ?? false
        searxngURL = try c.decodeIfPresent(String.self, forKey: .searxngURL) ?? PersistedSettings.defaults.searxngURL
        maxBrowseCharacters = try c.decodeIfPresent(Int.self, forKey: .maxBrowseCharacters) ?? 10000
        maxToolRounds = min(max(try c.decodeIfPresent(Int.self, forKey: .maxToolRounds) ?? 8, 1), 12)
        keepMultipleImagesInHistory = try c.decodeIfPresent(Bool.self, forKey: .keepMultipleImagesInHistory) ?? false
        let defaultHotkeyMap = Dictionary(
            uniqueKeysWithValues: Hotkey.defaultMap.map { ($0.key.rawValue, $0.value) }
        )
        hotkeys = try c.decodeIfPresent([String: Hotkey].self, forKey: .hotkeys) ?? defaultHotkeyMap
        if (try c.decodeIfPresent(Int.self, forKey: .hotkeyDefaultsVersion) ?? 1) < 2 {
            hotkeys = Hotkey.migratedFromLegacyDefaults(hotkeys)
        }
        hotkeyDefaultsVersion = 2
        toolStates = try c.decodeIfPresent([String: Bool].self, forKey: .toolStates) ?? [:]
        autoLabelingEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoLabelingEnabled) ?? true
        autoImageToTextEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoImageToTextEnabled) ?? true
        isSemanticSearchEnabled = try c.decodeIfPresent(Bool.self, forKey: .isSemanticSearchEnabled) ?? false
        imageExtractionDetail = try c.decodeIfPresent(String.self, forKey: .imageExtractionDetail) ?? "Normal"
        extractImagesFromPDF = try c.decodeIfPresent(Bool.self, forKey: .extractImagesFromPDF) ?? true
        appTheme = try c.decodeIfPresent(String.self, forKey: .appTheme) ?? "System"
        // Migration von der alten Klein/Mittel/Groß-Auswahl (String) auf den stufenlosen
        // Multiplikator (Double). Neuere Dateien haben hier bereits eine Zahl.
        if let scale = try? c.decodeIfPresent(Double.self, forKey: .chatFontSize) {
            chatFontSize = scale
        } else if let legacy = try? c.decodeIfPresent(String.self, forKey: .chatFontSize) {
            switch legacy {
            case "Small": chatFontSize = 0.85
            case "Large": chatFontSize = 1.2
            default: chatFontSize = 1.0
            }
        } else {
            chatFontSize = 1.0
        }
        isMenuBarApp = try c.decodeIfPresent(Bool.self, forKey: .isMenuBarApp) ?? false
        disableThinkingForBackgroundJobs = try c.decodeIfPresent(Bool.self, forKey: .disableThinkingForBackgroundJobs) ?? false
        showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? false
        // Phase H: decodeIfPresent mit den Defaults aus PersistedSettings.defaults als Fallback
        // – Bestandsinstallationen ohne diese Schlüssel laufen ohne Migration weiter.
        autoCompactSuggestionsEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoCompactSuggestionsEnabled) ?? true
        autoCompactThreshold = try c.decodeIfPresent(Double.self, forKey: .autoCompactThreshold) ?? 0.75
        compactSummaryTokens = try c.decodeIfPresent(Int.self, forKey: .compactSummaryTokens) ?? 6_000
        compactKeepLastMessages = try c.decodeIfPresent(Int.self, forKey: .compactKeepLastMessages) ?? 2
        research = (try? c.decodeIfPresent(ResearchSettings.self, forKey: .research)) ?? ResearchSettings()
        autoInstallPythonPackages = try c.decodeIfPresent(Bool.self, forKey: .autoInstallPythonPackages) ?? false
        youtubeSubtitleLanguage = try c.decodeIfPresent(String.self, forKey: .youtubeSubtitleLanguage) ?? "de"
        youtubeTranscriptCharLimit = try c.decodeIfPresent(Int.self, forKey: .youtubeTranscriptCharLimit) ?? 30_000
        customArchiveFolders = try c.decodeIfPresent([String].self, forKey: .customArchiveFolders) ?? []

        if let decodedProfiles = try c.decodeIfPresent([EndpointProfile].self, forKey: .profiles), !decodedProfiles.isEmpty {
            profiles = decodedProfiles
            activeProfileID = try c.decodeIfPresent(UUID.self, forKey: .activeProfileID) ?? decodedProfiles[0].id
            fallbackProfileID = try c.decodeIfPresent(UUID.self, forKey: .fallbackProfileID)
        } else {
            // Migration aus dem Phase-2-Flachformat.
            let endpoint = try c.decodeIfPresent(String.self, forKey: .legacyApiEndpoint) ?? PersistedSettings.defaults.profiles[0].baseURL
            let apiKey = try c.decodeIfPresent(String.self, forKey: .legacyApiKey) ?? ""
            let model = try c.decodeIfPresent(String.self, forKey: .legacyModelName) ?? "local-model"
            let migrated = EndpointProfile(name: "Lokal", baseURL: endpoint, apiKey: apiKey, model: model, isRemote: false)
            profiles = [migrated]
            activeProfileID = migrated.id
            fallbackProfileID = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(profiles, forKey: .profiles)
        try c.encodeIfPresent(activeProfileID, forKey: .activeProfileID)
        try c.encodeIfPresent(fallbackProfileID, forKey: .fallbackProfileID)
        try c.encode(learningStyle, forKey: .learningStyle)
        try c.encode(customPrompts, forKey: .customPrompts)
        try c.encode(searchEnabled, forKey: .searchEnabled)
        try c.encode(searxngURL, forKey: .searxngURL)
        try c.encode(maxBrowseCharacters, forKey: .maxBrowseCharacters)
        try c.encode(maxToolRounds, forKey: .maxToolRounds)
        try c.encode(keepMultipleImagesInHistory, forKey: .keepMultipleImagesInHistory)
        try c.encode(hotkeys, forKey: .hotkeys)
        try c.encode(hotkeyDefaultsVersion, forKey: .hotkeyDefaultsVersion)
        try c.encode(toolStates, forKey: .toolStates)
        try c.encode(autoLabelingEnabled, forKey: .autoLabelingEnabled)
        try c.encode(autoImageToTextEnabled, forKey: .autoImageToTextEnabled)
        try c.encode(isSemanticSearchEnabled, forKey: .isSemanticSearchEnabled)
        try c.encode(imageExtractionDetail, forKey: .imageExtractionDetail)
        try c.encode(extractImagesFromPDF, forKey: .extractImagesFromPDF)
        try c.encode(appTheme, forKey: .appTheme)
        try c.encode(chatFontSize, forKey: .chatFontSize)
        try c.encode(isMenuBarApp, forKey: .isMenuBarApp)
        try c.encode(disableThinkingForBackgroundJobs, forKey: .disableThinkingForBackgroundJobs)
        try c.encode(showMenuBarIcon, forKey: .showMenuBarIcon)
        try c.encode(autoCompactSuggestionsEnabled, forKey: .autoCompactSuggestionsEnabled)
        try c.encode(autoCompactThreshold, forKey: .autoCompactThreshold)
        try c.encode(compactSummaryTokens, forKey: .compactSummaryTokens)
        try c.encode(compactKeepLastMessages, forKey: .compactKeepLastMessages)
        try c.encode(research, forKey: .research)
        try c.encode(autoInstallPythonPackages, forKey: .autoInstallPythonPackages)
        try c.encode(youtubeSubtitleLanguage, forKey: .youtubeSubtitleLanguage)
        try c.encode(youtubeTranscriptCharLimit, forKey: .youtubeTranscriptCharLimit)
        try c.encode(customArchiveFolders, forKey: .customArchiveFolders)
    }
}

/// Lädt/speichert Einstellungen als JSON-Datei statt UserDefaults – einfacher zu inspizieren,
/// zu sichern und (später) über mehrere Endpunkt-Profile hinweg zu erweitern.
/// Migriert einmalig aus den alten UserDefaults-Keys, falls noch keine settings.json existiert.
final class SettingsStore {
    static let shared = SettingsStore()

    /// Zuletzt aus dem bzw. in den Schlüsselbund übertragener Key je Profil. Nur Änderungen
    /// werden zurückgeschrieben – Profile, deren Key beim Laden NICHT lesbar war, fehlen hier
    /// und werden erst angefasst, wenn der Nutzer selbst einen neuen Key einträgt.
    private var persistedKeys: [UUID: String] = [:]
    private var unreadableKeyProfiles: Set<UUID> = []

    func load() -> PersistedSettings {
        var settings: PersistedSettings
        if let data = try? Data(contentsOf: AppStorageLocation.settingsFile) {
            do {
                settings = try JSONDecoder().decode(PersistedSettings.self, from: data)
            } catch {
                // Audit H8: Eine korrupte settings.json führte vorher still zum Total-Reset –
                // der nächste save() überschrieb die Datei unwiderruflich mit den Defaults.
                // Jetzt wird die kaputte Datei VORHER als Backup neben der Einstellungsdatei
                // gesichert (settings.corrupt-<Zeitstempel>.json), damit sie manuell reparier-
                // bar bleibt, bevor die Defaults greifen.
                AppLog.persistence.error("settings.json beschädigt (\(error.localizedDescription)) – Backup angelegt, fahre mit Defaults fort.")
                let stamp = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                let backupURL = AppStorageLocation.settingsFile.deletingLastPathComponent()
                    .appendingPathComponent("settings.corrupt-\(stamp).json")
                try? data.write(to: backupURL, options: .atomic)
                settings = migrateFromUserDefaultsIfPresent() ?? .defaults
            }
        } else {
            // Keine settings.json vorhanden → einmalige Migration aus UserDefaults (Alt-Version der App).
            settings = migrateFromUserDefaultsIfPresent() ?? .defaults
        }
        // API-Keys aus der Keychain einschleusen (Audit P1): In settings.json stehen nur noch
        // leere Strings; die Profile im Speicher bekommen hier die echten Keys zurück.
        for idx in settings.profiles.indices {
            let id = settings.profiles[idx].id
            switch KeychainStore.readAPIKey(forProfileID: id) {
            case .found(let key):
                settings.profiles[idx].apiKey = key
                persistedKeys[id] = key
            case .notFound:
                settings.profiles[idx].apiKey = ""
                persistedKeys[id] = ""
            case .failed:
                settings.profiles[idx].apiKey = ""
                unreadableKeyProfiles.insert(id)
            }
        }
        return settings
    }

    func save(_ settings: PersistedSettings) {
        // API-Keys raus aus der JSON-Datei (Audit P1): Vorher lagen sie im Klartext in
        // settings.json – jede App/ein jedes Backup/einSync-Dienst konnte sie mitlesen.
        // Die Keys wandern in die Keychain, ins JSON wird nur ein leerer String geschrieben.
        var sanitized = settings
        for idx in sanitized.profiles.indices {
            let id = sanitized.profiles[idx].id
            let key = sanitized.profiles[idx].apiKey
            if unreadableKeyProfiles.contains(id) {
                // Nicht lesbarer Eintrag: Ein leerer Key im Speicher ist kein Löschwunsch.
                // Erst ein vom Nutzer eingetragener Key überschreibt den Eintrag.
                if !key.isEmpty {
                    KeychainStore.setAPIKey(key, forProfileID: id)
                    unreadableKeyProfiles.remove(id)
                    persistedKeys[id] = key
                }
            } else if persistedKeys[id] != key {
                KeychainStore.setAPIKey(key, forProfileID: id)
                persistedKeys[id] = key
            }
            sanitized.profiles[idx].apiKey = ""
        }
        do {
            let data = try JSONEncoder().encode(sanitized)
            try AppStorageLocation.writeAtomically(data, to: AppStorageLocation.settingsFile)
        } catch {
            // Vorher war das ein stummes `try?` (Audit P2): Bei Disk-Full o. Ä. gingen
            // Änderungen kommentarlos verloren. Jetzt wenigstens diagnostizierbar geloggt.
            AppLog.persistence.error("Settings konnten nicht gespeichert werden: \(error.localizedDescription)")
        }
    }

    /// Migration direkt aus den UserDefaults-Keys der allerersten App-Version (vor Phase 2/3,
    /// als noch gar keine settings.json existierte). Neuere Dateien (Phase-2-Flachformat)
    /// werden bereits von `PersistedSettings.init(from:)` selbst migriert.
    private func migrateFromUserDefaultsIfPresent() -> PersistedSettings? {
        let ud = UserDefaults.standard
        guard ud.object(forKey: "lernassist_apiEndpoint") != nil
            || ud.object(forKey: "lernassist_modelName") != nil else {
            return nil
        }
        var s = PersistedSettings.defaults
        if let prompts = ud.dictionary(forKey: "lernassist_customPrompts") as? [String: String] {
            s.customPrompts = prompts
        }

        var profile = s.profiles[0]
        if let ep = ud.string(forKey: "lernassist_apiEndpoint"), !ep.isEmpty { profile.baseURL = ep }
        if let key = ud.string(forKey: "lernassist_apiKey") { profile.apiKey = key }
        if let mn = ud.string(forKey: "lernassist_modelName"), !mn.isEmpty { profile.model = mn }
        s.profiles = [profile]
        s.activeProfileID = profile.id

        if let style = ud.string(forKey: "lernassist_learningStyle") { s.learningStyle = style }
        s.searchEnabled = ud.bool(forKey: "lernassist_searchEnabled")
        if let su = ud.string(forKey: "lernassist_searxngURL"), !su.isEmpty { s.searxngURL = su }
        let maxChars = ud.integer(forKey: "lernassist_maxBrowseCharacters")
        if maxChars > 0 { s.maxBrowseCharacters = maxChars }

        save(s) // sofort als settings.json persistieren, damit die Migration nur einmal läuft

        // Audit M15: Der Legacy-API-Key lag nach der Migration weiterhin im Klartext in der
        // UserDefaults-plist – save() hat ihn in die Keychain geschrieben, aber nie entfernt.
        // Der Fallback gilt nur für Neuinstallationen; Altinstallationen behielten das Leak.
        // Jetzt wird er aus der plist gelöscht; die Keychain-Kopie ist die einzige verbleibende.
        UserDefaults.standard.removeObject(forKey: "lernassist_apiKey")
        return s
    }
}
