import Foundation
import SwiftUI
import AppKit
import Combine
import os

/// Eine Folgefrage/ein Screenshot, die/der während einer laufenden Modell-Antwort abgeschickt
/// wurde. Wird nicht sofort gesendet (das würde den laufenden Stream killen und den KV-Cache-
/// Vorteil der Konversation zunichtemachen), sondern angezeigt und automatisch nachgereicht,
/// sobald die aktuelle Generierung fertig ist.
struct QueuedMessage: Identifiable {
    let id = UUID()
    var text: String
    var imageBase64: String?
    /// Chat, in den die Nachricht abgeschickt wurde – sie wird nur dort nachgereicht.
    var sessionId: UUID? = nil
}

// MARK: - ViewModel

class ChatViewModel: ObservableObject, @unchecked Sendable {
    @Published var sessions: [ChatSession]
    @Published var archivedSessions: [ChatSession] = []
    /// Chats, die gelöscht wurden, aber noch nicht endgültig entfernt sind – Löschen (egal ob aktiv
    /// oder archiviert) landet zuerst hier, bevor es wirklich unwiderruflich wird.
    @Published var trashedSessions: [ChatSession] = []
    @Published var customArchiveFolders: [String] = []
    @Published var activeSessionId: UUID
    @Published var isStreaming: Bool = false {
        didSet {
            // Sobald eine Generierung endet (normal fertig oder mit Fehler – nicht bei
            // Nutzer-Abbruch oder fehlgeschlagenem Runden-Start, siehe suppressQueueAutoAdvance),
            // wird automatisch die nächste gequeute Nachricht nachgereicht, statt dass der Nutzer
            // sie manuell erneut abschicken muss.
            if oldValue && !isStreaming {
                persistStreamedSessionIfInactive()
            }
            if oldValue && !isStreaming && !suppressQueueAutoAdvance {
                sendNextQueuedMessageIfAny()
            }
        }
    }
    /// Nachrichten, die während einer laufenden Antwort abgeschickt wurden und auf ihre Reihe warten.
    @Published var queuedMessages: [QueuedMessage] = []
    @Published var learningStyle: LearningStyle = .beginner
    /// Custom-Prompts je Lernmodus, persistiert in settings.json.
    @Published var customPrompts: [String: String] = [:]
    /// Websuche via Tool-Calling aktivieren
    @Published var searchEnabled: Bool = false
    /// SearXNG-Basis-URL (auf diesem Mac z.B. http://127.0.0.1:8082)
    @Published var searxngURL: String = "http://127.0.0.1:8082"
    /// Maximale Zeichenanzahl für das browse_url Tool (Standard 10.000)
    @Published var maxBrowseCharacters: Int = 10000
    /// Maximale aufeinanderfolgende Tool-Runden pro Modell-Turn (konfigurierbar, Standard 8).
    @Published var maxToolRounds: Int = 8
    /// Phase 7C: Hintergrund-Aufgaben
    @Published var autoLabelingEnabled: Bool = true
    @Published var autoImageToTextEnabled: Bool = true
    @Published var extractImagesFromPDF: Bool = true
    @Published var isSemanticSearchEnabled: Bool = false
    @Published var imageExtractionDetail: String = "Normal"
    @Published var appTheme: String = "System"
    /// Schriftgrößen-Multiplikator (0.8...1.5) für den Chat-Inhalt, stufenlos per Slider.
    @Published var chatFontSize: Double = 1.0
    @Published var isMenuBarApp: Bool = false
    /// Unabhängig von isMenuBarApp: ob zusätzlich ein Symbol in der Menüleiste erscheint. Vorher
    /// zwingend an "kein Dock-Icon" gekoppelt – jetzt frei kombinierbar (z.B. Dock-Icon UND
    /// Menüleisten-Symbol gleichzeitig, oder beides aus).
    @Published var showMenuBarIcon: Bool = false
    /// Best-effort "Thinking" für Hintergrund-Jobs deaktivieren (siehe sendInvisiblePrompt) –
    /// hilft z.B. bei Qwen3-artigen Modellen, Titel-/Bild-/Zusammenfassungs-Jobs nicht unnötig
    /// lange über einen internen Denkprozess laufen zu lassen.
    @Published var disableThinkingForBackgroundJobs: Bool = false

    // MARK: - Konfigurierbare Werte der Phase-H-Features (Einstellungen → Erweitert)
    /// Auto-Kompakt-Angebot: „Zusammenfassen"-Chip in der Chat-Leiste, wenn der Chat lang wird.
    @Published var autoCompactSuggestionsEnabled: Bool = true
    /// Schwellwert (0...1) des geschätzten Kontext-Füllstands für das Angebot.
    @Published var autoCompactThreshold: Double = 0.75
    @Published var compactSummaryTokens: Int = 6_000
    @Published var compactKeepLastMessages: Int = 2
    /// Websuche: Quellen, Reranker, Budgets (Einstellungen → Recherche).
    @Published var research = ResearchSettings() {
        didSet { if research != oldValue { syncResearchConfiguration() } }
    }
    /// Python-Pakete für coding_sandbox ohne Rückfrage installieren.
    @Published var autoInstallPythonPackages = false {
        didSet { CodingEnvironment.shared.autoInstallPackages = autoInstallPythonPackages }
    }
    /// Zustand der eigenen Python-Umgebung (Einstellungen → Tools).
    @Published var pythonEnvironmentStatus: PythonEnvironmentStatus = .unknown

    /// Exa-API-Key (Schlüsselbund). Leer = kostenlose Stufe.
    @Published var exaAPIKey: String = KeychainStore.secret(account: "exa") {
        didSet {
            guard exaAPIKey != oldValue else { return }
            KeychainStore.setSecret(exaAPIKey, account: "exa")
            syncResearchConfiguration()
        }
    }
    /// Bevorzugte Untertitel-Sprache für den YouTube-Import (BCP-47-Kurzcode, "" = erste Spur).
    @Published var youtubeSubtitleLanguage: String = "de"
    /// Max. Zeichen, die ein YouTube-Transkript in den Chat-Kontext einbringt.
    @Published var youtubeTranscriptCharLimit: Int = 30_000

    // MARK: - Endpunkt-Profile (Phase 3)
    @Published var profiles: [EndpointProfile] = []
    @Published var activeProfileID: UUID?
    @Published var fallbackProfileID: UUID?
    /// True während die aktuelle Antwort über das Fallback-Profil läuft (Remote nicht erreichbar).
    @Published var isUsingFallback: Bool = false
    /// Wenn true, werden alle Bilder im Verlauf (nicht nur das neueste) erneut mitgeschickt.
    @Published var keepMultipleImagesInHistory: Bool = false
    /// Belegbare Tastenkombinationen je Aktion (HotkeyAction → Hotkey).
    @Published var hotkeys: [HotkeyAction: Hotkey] = Dictionary(
        uniqueKeysWithValues: Hotkey.defaultMap.map { ($0.key, $0.value) }
    )
    /// Aktuellste Metriken (Tokens, Tok/s, Cache) aus dem letzten Streaming-Chunk.
    @Published var currentMetrics: ChatMetrics = .empty
    /// Statusnachricht für Hintergrund-Jobs (z.B. "Prozessiere Bilder..."), nil wenn inaktiv
    @Published var backgroundJobStatus: String?
    /// LM Studio Verbindungs-/Lade-Status für UI-Badge (nur bei lokalem LM Studio-Profil relevant)
    @Published var lmStudioStatus: LMStudioStatus = .idle
    /// Das Hauptmodell, das LMStudioModelManager aktuell für uns "acquired" hält (siehe sendMessage).
    /// Bewusst OHNE den kurzen Idle-Unload-Timer, den das Hintergrund-Helfermodell nutzt – das
    /// Hauptmodell soll während der aktiven Konversation durchgehend geladen bleiben (jedes
    /// Entladen zwischen zwei Nachrichten würde sowohl die Ladezeit erneut fällig machen als auch
    /// den serverseitigen KV-Cache für die Konversation zerstören). Wird nur beim tatsächlichen
    /// Profil-/Modellwechsel freigegeben, damit nicht mehrere ausprobierte Modelle dauerhaft im
    /// RAM bleiben.
    var heldMainModel: (instanceId: String, modelId: String, baseURL: String, apiKey: String)?

    var activeProfile: EndpointProfile? {
        profiles.first(where: { $0.id == activeProfileID }) ?? profiles.first
    }

    /// Laufender Stream (LLMClient). Canceln beendet auch den Netzwerk-Request.
    var currentStreamTask: Task<Void, Never>?
    /// Generations-Token des aktiven Antwort-Durchlaufs (Audit H2/H3): Jede logische Antwort-Runde
    /// bekommt eine neue UUID, cancelStreaming() rotiert sie. Verspätet eintreffende Callbacks
    /// (Retry nach 1,5 s, Fallback nach Sekunden dauerndem LM-Studio-Modellladen, cancelter
    /// Tool-Task) prüfen gegen dieses Token – sie dürfen den Zustand eines bereits danach
    /// gestarteten neuen Durchlaufs nicht mehr anfassen.
    var streamGeneration = UUID()
    /// Geplanter Retry-/Fallback-Stream (Audit H2): als Task-Handle gespeichert, damit
    /// cancelStreaming() ihn stoppen kann – der frühere DispatchQueue.asyncAfter lief nach dem
    /// Nutzer-Abbruch trotzdem aus und startete heimlich einen neuen Stream.
    var pendingStreamRetryTask: Task<Void, Never>?
    /// Unterdrückt das automatische Nachreichen der nächsten Queue-Nachricht (Audit M1/M4): Nach
    /// Nutzer-Abbruch oder gescheitertem Runden-Start darf keine Folgenachricht automatisch gegen
    /// denselben kaputten Endpunkt gesendet werden. Normal beendete Runden feuern weiter.
    var suppressQueueAutoAdvance = false
    /// Chat der laufenden Antwort: Der Autosave schreibt nur den aktiven Chat – endet eine Antwort,
    /// während ein anderer Chat offen ist, wird ihr Chat hier nachträglich gesichert.
    var streamingSessionId: UUID?

    func persistStreamedSessionIfInactive() {
        guard let id = streamingSessionId else { return }
        streamingSessionId = nil
        guard id != activeSessionId, let session = sessions.first(where: { $0.id == id }) else { return }
        SessionStore.shared.save(session)
    }
    /// IDs des laufenden Streams – erlaubt cancelStreaming(), gepufferte Chunks vor dem Abbruch
    /// noch in die Nachricht zu schreiben, damit bereits gestreamter Text nicht verloren geht.
    var currentStreamIds: (sessionId: UUID, targetMsgId: UUID)?
    /// Task, der gerade Tool-Results einsammelt und den Folge-Stream startet (siehe handleFinished).
    /// Muss von cancelStreaming() mit abgebrochen werden – sonst startete er nach dem Abbruch
    /// heimlich einen neuen Stream, während die UI bereits "idle" zeigte.
    var toolContinuationTask: Task<Void, Never>?
    /// Verhindert endlose Tool-Calling-Rekursion. Der Wert bleibt in den Settings begrenzt,
    /// damit ein fehlerhafter Server/Prompt den Turn nicht unbegrenzt offen hält.
    var toolCallDepth = 0
    /// Signaturen fehlgeschlagener Tool-Aufrufe im aktuellen Nutzer-Turn. Ein identischer
    /// Aufruf wird nach dem ersten Fehler nicht nochmals ausgeführt: Das Modell erhält stattdessen
    /// ein sichtbares Ergebnis und kann nur mit geänderten Argumenten sinnvoll iterieren. Dadurch
    /// wird ein wiederholter Python-/Terminal-Fehler zu einer kurzen Korrekturschleife statt zu
    /// einer Serie identischer Tool-Aufrufe.
    var blockedToolInvocationSignatures: Set<String> = []
    /// Harte Obergrenze für parallele Calls in einer Modellrunde. Zusammen mit dem einstellbaren
    /// Rundenlimit bleibt damit auch ein fehlerhaftes Modell bei maximal 4 × maxToolRounds
    /// logischen Tool-Aufrufen pro Nutzer-Turn.
    static let maxToolCallsPerRound = 4
    /// Verhindert doppelte gleichzeitige Hintergrund-Jobs (Phase 7C) pro Session/Nachricht.
    var titlingInProgress: Set<UUID> = []
    var describingImages: Set<UUID> = []

    // Performance: Throttling für Streaming-Updates
    var contentBuffer = ""
    var thinkingBuffer = ""
    var updateTimer: AnyCancellable?

    // Client-seitige TPS-Messung (Fallback wenn Server keine Tok/s liefert)
    var streamStartTime: Date?
    var firstTokenTime: Date?

    // Persistenz: Autosave & Termination-Flush
    var autosaveCancellable: AnyCancellable?
    /// Persistenz-Audit: Debounce-Autosave für ALLE Nicht-Profil-Einstellungen (siehe
    /// setupAutosave – vorher waren sie nur per „Fertig“-Klick oder beim App-Beenden gesichert).
    var settingsAutosaveCancellable: AnyCancellable?
    var activeSessionCancellable: AnyCancellable?
    var profilesAutosaveCancellable: AnyCancellable?
    var lastAutosavedActiveId: UUID?
    var terminationObserver: Any?
    var themeCancellable: AnyCancellable?
    var contextWindowCancellable: AnyCancellable?

    /// Slash-Befehle dieser Instanz (Audit M13): keine geteilte Registry mehr – jede Instanz
    /// registriert ihre Befehle mit ihrem eigenen `weak self`, siehe SlashCommandRegistry.
    let slashCommandRegistry = SlashCommandRegistry()

    /// Auto-Kompakt (Phase H): True, sobald der aktive Chat sich dem Kontextfenster nähert
    /// (> 75 % geschätzter Füllstand) – die Chat-Leiste zeigt dann ein Angebot, den Chat per
    /// /compact zusammenzufassen. Bewusst ein Flag statt automatischer Aktion: Der Nutzer soll
    /// entscheiden, ob der Verlauf gekürzt wird. Wird nur von refreshCompactionHint()/compact
    /// gesetzt ( interne Setter-Konvention, da die Logik in ChatViewModel+StudyFeatures liegt).
    @Published var shouldSuggestCompaction: Bool = false

    init() {
        let restored = SessionStore.shared.loadAllActive()
        if restored.isEmpty {
            let id = UUID()
            self.activeSessionId = id
            self.sessions = [ChatSession(id: id, title: "Neuer Chat")]
        } else {
            self.sessions = restored
            self.activeSessionId = restored[0].id
        }
        self.archivedSessions = SessionStore.shared.loadAllArchived()
        self.trashedSessions = SessionStore.shared.loadAllTrashed()

        loadSettings()
        setupAutosave()
        lastAutosavedActiveId = activeSessionId
        setupTerminationFlush()
        syncToolRegistry()
        setupSlashCommands()
        autoArchiveOldSessions()
        applyAppTheme()
        themeCancellable = $appTheme.dropFirst().sink { [weak self] _ in self?.applyAppTheme() }

        // Kontextfenster-Größe automatisch abfragen statt der festen 8192-Annahme in der
        // MetricsBar: einmal beim Start, danach bei jedem Profilwechsel. Kein manuelles
        // "Modelle laden" in den Settings mehr nötig.
        refreshContextWindowForActiveProfile()
        contextWindowCancellable = $activeProfileID.dropFirst().sink { [weak self] _ in
            self?.refreshContextWindowForActiveProfile()
        }

        // LM Studio: beim Start abgleichen, welche Modelle dort schon laufen (z.B. aus einer
        // vorherigen Sitzung noch geladen) – ohne das würde die App beim ersten Senden immer von
        // "nicht geladen" ausgehen und unnötig einen Lade-Request schicken, selbst wenn das Modell
        // längst bereit ist.
        if let profile = activeProfile {
            Task {
                let manager = LMStudioModelManager.shared
                if manager.isLMStudioLocal(profile: profile) {
                    await manager.syncLoadedModels(baseURL: profile.baseURL, apiKey: profile.apiKey)
                }
            }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        // Hinweis zu heldMainModel (Audit 2.7): Ein Release in deinit ist nicht möglich
        // (deinit kann nicht awaiten) – und der Fall "VM dealloc'iert" tritt praktisch nur
        // zusammen mit dem App-Exit ein, für den setupTerminationFlush() das LM-Studio-
        // Modell zuverlässig freigibt (dort wird heldMainModel explizit released).
    }

    // MARK: - Persistenz (Sessions)

    /// Verwandelt einen Publisher in ein Void-Änderungssignal ohne das initiale Echo
    /// (Published sendet beim Abonnieren sofort den aktuellen Wert – dropFirst entfernt
    /// genau dieses Echo, echte Änderungen laufen unverändert durch).
    func changedSignal<P: Publisher>(_ publisher: P) -> AnyPublisher<Void, Never> where P.Failure == Never {
        publisher.dropFirst().map { _ in () }.eraseToAnyPublisher()
    }

    /// Speichert Änderungen an `sessions` gedrosselt (1s nach der letzten Änderung), damit
    /// Streaming (mehrere Content-Updates pro Sekunde) nicht bei jedem Zeichen aufs Dateisystem
    /// schreibt. Ein sofortiger Flush erfolgt zusätzlich beim Beenden der App (s. u.).
    func setupAutosave() {
        // Nur die AKTIVE Session schreiben: Alle anderen Sessions ändern sich ausschließlich
        // über Pfade, die selbst explizit speichern (togglePin, Archiv/Ordner, Flashcards, ...).
        // Vorher wurde bei jeder Änderung – d.h. während des Streamings einmal pro Sekunde –
        // der komplette Session-Bestand neu serialisiert und geschrieben.
        autosaveCancellable = $sessions
            .dropFirst() // die initiale Zuweisung aus init() muss nicht erneut geschrieben werden
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] sessions in
                guard let self else { return }
                if let active = sessions.first(where: { $0.id == self.activeSessionId }) {
                    SessionStore.shared.save(active)
                }
            }
        // Persistenz-Audit – globaler Einstellungs-Autosave: ALLE weiteren Einstellungen
        // (nicht nur Profile) mit demselben Debounce-Schutz wie Profile speichern. Vorher
        // waren sie erst beim „Fertig“-Klick des Settings-Sheets oder beim App-Beenden
        // (Termination-Flush) gesichert – ESC/X-Close plus Crash hätte Lernmodi-Custom-Prompts,
        // Such-URL, Schriftgröße, Theme, Ordnerliste, Phase-H-Werte usw. kosten können.
        // changeCount-stark gedrosselt (1 s), Save-Inhalt ist immer der komplette Snapshot.
        let settingsChanged: [AnyPublisher<Void, Never>] = [
            changedSignal($learningStyle),
            changedSignal($customPrompts),
            changedSignal($searchEnabled),
            changedSignal($searxngURL),
            changedSignal($maxBrowseCharacters),
            changedSignal($maxToolRounds),
            changedSignal($keepMultipleImagesInHistory),
            changedSignal($hotkeys),
            changedSignal($autoLabelingEnabled),
            changedSignal($autoImageToTextEnabled),
            changedSignal($extractImagesFromPDF),
            changedSignal($isSemanticSearchEnabled),
            changedSignal($imageExtractionDetail),
            changedSignal($appTheme),
            changedSignal($chatFontSize),
            changedSignal($isMenuBarApp),
            changedSignal($showMenuBarIcon),
            changedSignal($disableThinkingForBackgroundJobs),
            changedSignal($autoCompactSuggestionsEnabled),
            changedSignal($autoCompactThreshold),
            changedSignal($compactSummaryTokens),
            changedSignal($compactKeepLastMessages),
            changedSignal($research),
            changedSignal($autoInstallPythonPackages),
            changedSignal($youtubeSubtitleLanguage),
            changedSignal($youtubeTranscriptCharLimit),
            changedSignal($customArchiveFolders),
        ]
        settingsAutosaveCancellable = Publishers.MergeMany(settingsChanged)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.saveSettings() }

        // Beim Session-Wechsel die zuvor aktive Session sofort sichern, damit die letzte
        // Sekunde (Debounce-Fenster) an Inhaltsänderungen nicht verloren geht.
        activeSessionCancellable = $activeSessionId
            .dropFirst()
            .sink { [weak self] newId in
                guard let self else { return }
                if let prev = self.lastAutosavedActiveId,
                   prev != newId,
                   let prevSession = self.sessions.first(where: { $0.id == prev }) {
                    SessionStore.shared.save(prevSession)
                }
                self.lastAutosavedActiveId = newId
                // Kompakt-Chip nicht veralten lassen (Perf-Audit K3): Der Füllstand gehört zum
                // jeweils aktiven Chat – ohne diesen Refresh blieb ein Angebot aus einem vollen
                // Chat nach dem Wechsel auf einen leeren stehen (und "komprimierte" dann den falschen).
                self.refreshCompactionHint()
            }
        // Profil-Änderungen (Endpunkt-URL, API-Key, Parameter, Modell) automatisch sichern.
        // Vorher wurden Edits erst beim Klick auf "Fertig" oder beim App-Beenden persistiert –
        // ein per ESC geschlossenes Settings-Sheet oder ein Crash bedeutete kompletten
        // Verlust aller Profil-Änderungen.
        profilesAutosaveCancellable = $profiles
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.saveSettings()
            }
    }

    func setupTerminationFlush() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            for session in self.sessions { SessionStore.shared.save(session) }
            SettingsStore.shared.save(self.currentPersistedSettings())
            // Gehaltenes LM-Studio-Hauptmodell best-effort freigeben, damit es nicht nach dem
            // App-Ende weiter geladen bleibt. (Best-effort, da der Prozess kurz danach endet –
            // LM Studio entlädt spätestens beim Verbindungsabbau selbst.)
            if let held = self.heldMainModel {
                let manager = LMStudioModelManager.shared
                let instanceId = held.instanceId, modelId = held.modelId
                let baseURL = held.baseURL, apiKey = held.apiKey
                Task { await manager.release(instanceId: instanceId, modelId: modelId, baseURL: baseURL, apiKey: apiKey) }
            }
        }
    }

    /// Pinnt/löst einen aktiven Chat – gepinnte Chats sortieren in der Sidebar immer nach oben.
    func togglePin(id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].isPinned = !(sessions[idx].isPinned ?? false)
        SessionStore.shared.save(sessions[idx])
    }

    func archiveSession(id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: idx)
        archivedSessions.insert(session, at: 0)
        SessionStore.shared.archive(session)
        if sessions.isEmpty { createNewChat() }
        else if activeSessionId == id { activeSessionId = sessions[0].id }
    }
    
    func updateFlashcards(for id: UUID, flashcards: [Flashcard]) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].flashcards = flashcards
            SessionStore.shared.save(sessions[idx])
        } else if let idx = archivedSessions.firstIndex(where: { $0.id == id }) {
            archivedSessions[idx].flashcards = flashcards
            // War vorher `save(archivedSessions[idx])` OHNE `archived: true` – der Default-Parameter
            // ist `false`, wodurch eine archivierte Session bei jedem Karteikarten-Update fälschlich
            // (zusätzlich, als Dublette) in sessions/ statt archive/ geschrieben wurde.
            SessionStore.shared.save(archivedSessions[idx], archived: true)
        }
    }

    func updateFlashcardSets(for id: UUID, sets: [FlashcardSet]) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].flashcardSets = sets
            SessionStore.shared.save(sessions[idx])
        } else if let idx = archivedSessions.firstIndex(where: { $0.id == id }) {
            archivedSessions[idx].flashcardSets = sets
            SessionStore.shared.save(archivedSessions[idx], archived: true)
        }
    }

    /// Löscht ein einzelnes gespeichertes Karteikarten-Set (nicht den ganzen Chat). Die enthaltenen
    /// Karten fallen dadurch automatisch auch aus dem globalen "Fällig heute"-Stapel heraus, da
    /// dieser Set-übergreifend live aus `flashcardSets` aller Sessions gebildet wird.
    func deleteFlashcardSet(sessionId: UUID, setId: UUID) {
        if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[idx].flashcardSets?.removeAll { $0.id == setId }
            SessionStore.shared.save(sessions[idx])
        } else if let idx = archivedSessions.firstIndex(where: { $0.id == sessionId }) {
            archivedSessions[idx].flashcardSets?.removeAll { $0.id == setId }
            SessionStore.shared.save(archivedSessions[idx], archived: true)
        }
    }

    // MARK: - Globales Spaced-Repetition-System

    /// Alle Karteikarten aus JEDER Session (aktiv + archiviert), zusammen mit dem Kontext, wo sie
    /// herkommen – Grundlage für den globalen "Fällig heute"-Stapel. Archivierte Chats bleiben
    /// bewusst Teil des SRS-Systems: nur weil ein Chat nach 7 Tagen automatisch archiviert wird,
    /// sollen seine Karteikarten nicht aus der Wiederholung verschwinden.
    struct DueFlashcard: Identifiable {
        var id: UUID { card.id }
        let card: Flashcard
        let sessionId: UUID
        let sessionTitle: String
        let setId: UUID
        let setTitle: String
    }

    var allFlashcardsWithContext: [DueFlashcard] {
        var result: [DueFlashcard] = []
        for session in sessions + archivedSessions {
            guard let sets = session.flashcardSets else { continue }
            for set in sets {
                for card in set.cards {
                    result.append(DueFlashcard(card: card, sessionId: session.id, sessionTitle: session.title,
                                                setId: set.id, setTitle: set.title))
                }
            }
        }
        return result
    }

    /// Fällige Karten, älteste Fälligkeit zuerst.
    var dueFlashcards: [DueFlashcard] {
        let now = Date()
        return allFlashcardsWithContext
            .filter { $0.card.dueDate <= now }
            .sorted { $0.card.dueDate < $1.card.dueDate }
    }

    var dueFlashcardsCount: Int { dueFlashcards.count }

    /// Bewertet eine Karte (Nochmal/Schwer/Gut/Einfach), aktualisiert ihr SRS-Intervall und
    /// persistiert die Änderung – egal ob die Karte zu einem aktiven oder archivierten Chat gehört.
    func recordFlashcardReview(sessionId: UUID, setId: UUID, cardId: UUID, rating: FlashcardRating) {
        func apply(_ sets: inout [FlashcardSet]) -> Bool {
            guard let setIdx = sets.firstIndex(where: { $0.id == setId }),
                  let cardIdx = sets[setIdx].cards.firstIndex(where: { $0.id == cardId })
            else { return false }
            sets[setIdx].cards[cardIdx].applyReview(rating)
            return true
        }

        if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
            var sets = sessions[idx].flashcardSets ?? []
            guard apply(&sets) else { return }
            updateFlashcardSets(for: sessionId, sets: sets)
        } else if let idx = archivedSessions.firstIndex(where: { $0.id == sessionId }) {
            var sets = archivedSessions[idx].flashcardSets ?? []
            guard apply(&sets) else { return }
            updateFlashcardSets(for: sessionId, sets: sets)
        }
    }
    
    /// Archiviert alle aktiven Sessions, deren letzte Aktivität älter als 7 Tage ist
    func autoArchiveOldSessions() {
        let now = Date()
        let threshold = now.addingTimeInterval(-7 * 24 * 60 * 60) // 7 Tage
        
        let toArchive = sessions.filter { session in
            // Neuen, leeren Chat nicht sofort archivieren
            if session.messages.isEmpty && session.title == "Neuer Chat" { return false }
            return session.lastActivityDate < threshold
        }
        
        for session in toArchive {
            archiveSession(id: session.id)
        }
    }

    func unarchiveSession(id: UUID) {
        guard let idx = archivedSessions.firstIndex(where: { $0.id == id }) else { return }
        let session = archivedSessions.remove(at: idx)
        sessions.insert(session, at: 0)
        SessionStore.shared.unarchive(session)
        activeSessionId = session.id
    }

    /// Verschiebt eine archivierte Session in den Papierkorb, statt sie direkt endgültig zu löschen.
    func trashArchivedSession(id: UUID) {
        guard let idx = archivedSessions.firstIndex(where: { $0.id == id }) else { return }
        let session = archivedSessions.remove(at: idx)
        trashedSessions.insert(session, at: 0)
        SessionStore.shared.trash(session, wasArchived: true)
    }

    // MARK: - Papierkorb

    /// Stellt eine Session aus dem Papierkorb wieder her, zurück in die aktiven Chats.
    func restoreFromTrash(id: UUID) {
        guard let idx = trashedSessions.firstIndex(where: { $0.id == id }) else { return }
        let session = trashedSessions.remove(at: idx)
        sessions.insert(session, at: 0)
        SessionStore.shared.restoreFromTrash(session)
        activeSessionId = session.id
    }

    /// Entfernt eine Session aus dem Papierkorb endgültig – ab hier gibt es kein Zurück mehr.
    func deleteTrashedSessionPermanently(id: UUID) {
        guard let idx = trashedSessions.firstIndex(where: { $0.id == id }) else { return }
        let session = trashedSessions.remove(at: idx)
        SessionStore.shared.deletePermanently(trashedSession: session)
    }
    
    /// Leert den gesamten Papierkorb unwiderruflich.
    func emptyTrash() {
        for session in trashedSessions {
            SessionStore.shared.deletePermanently(trashedSession: session)
        }
        trashedSessions.removeAll()
    }
    
    func addCustomArchiveFolder(_ name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanName.isEmpty && !customArchiveFolders.contains(cleanName) {
            customArchiveFolders.append(cleanName)
        }
    }

    /// Übernimmt die Reihenfolge der Archiv-Ordner, wie sie in der Sidebar angezeigt wird
    /// (Sidebar U6): Die Indizes von onMove beziehen sich auf die sichtbare Ordnerliste –
    /// Ordner, die bislang nicht in `customArchiveFolders` standen ("Sonstige"), werden durch
    /// das Verschieben explizit geordnet und damit mit aufgenommen. (Die Ordnerliste ist wie
    /// bisher rein in-memory; persistiert werden nur die Folder-Zuordnungen der Sessions.)
    func reorderArchiveFolders(_ orderedKeys: [String]) {
        customArchiveFolders = orderedKeys
    }
    
    func deleteFolder(_ name: String) {
        customArchiveFolders.removeAll(where: { $0 == name })
        for i in 0..<archivedSessions.count {
            if archivedSessions[i].archiveFolder == name {
                archivedSessions[i].archiveFolder = nil
            }
        }
    }
    
    func moveSessionToFolder(id: UUID, folder: String) {
        let trimmedFolder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalFolder = trimmedFolder.isEmpty ? nil : trimmedFolder
        
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].archiveFolder = finalFolder
            archiveSession(id: id)
        } else if let idx = archivedSessions.firstIndex(where: { $0.id == id }) {
            archivedSessions[idx].archiveFolder = finalFolder
            SessionStore.shared.archive(archivedSessions[idx]) // Persist
        }
    }

    func renameSession(id: UUID, newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].title = trimmed
    }

    func createNewChat() {
        let s = ChatSession(title: "Neuer Chat")
        sessions.insert(s, at: 0)
        activeSessionId = s.id
    }

    /// Verschiebt eine aktive Session in den Papierkorb. Ersetzt das frühere sofortige, endgültige
    /// Löschen – der Löschen-Button bleibt bewusst ohne Rückfrage (siehe Feedback), landet aber
    /// jetzt erst im Papierkorb statt direkt unwiderruflich zu verschwinden.
    func trashSession(id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: idx)
        trashedSessions.insert(session, at: 0)
        SessionStore.shared.trash(session, wasArchived: false)
        if sessions.isEmpty { createNewChat() }
        else if activeSessionId == id { activeSessionId = sessions[0].id }
    }

    func cancelStreaming() {
        AppLog.chat.info("Streaming abgebrochen (Nutzer)")
        // Audit H2/H3: Generation rotieren – alle verspäteten Callbacks dieser Runde
        // (geplanter Retry, Fallback nach Modell-Laden, cancelter Tool-Task) sind damit
        // entwertet und starten/killen keinen Stream mehr.
        streamGeneration = UUID()
        pendingStreamRetryTask?.cancel()
        pendingStreamRetryTask = nil
        currentStreamTask?.cancel()
        currentStreamTask = nil
        updateTimer?.cancel()
        updateTimer = nil
        // Auch die laufende Tool-Runde stoppen: Der Tool-Task lief früher nach dem Abbruch
        // weiter und startete danach einen Folge-Stream, obwohl die UI bereits "idle" zeigte
        // (isStreaming == false) – die Queue-Logik konnte dann parallel eine zweite Nachricht
        // losschicken.
        toolContinuationTask?.cancel()
        toolContinuationTask = nil

        // Ge pufferte Chunks vor dem Abbruch noch in die Nachricht, damit der bereits
        // gestreamte Text nicht still verworfen wird (flushBuffers wendet synchron an,
        // da cancelStreaming vom Main-Thread aufgerufen wird).
        if let ids = currentStreamIds {
            flushBuffers(sessionId: ids.sessionId, targetMsgId: ids.targetMsgId)
        }

        // Audit M4: Nutzer-Abbruch soll die nächste gequeute Nachricht NICHT automatisch
        // nachreichen – der Nutzer bricht ab, weil die Antwort daneben geht; eine Folgenachricht
        // gegen denselben (unbrauchbaren) Kontext wäre kontraproduktiv.
        suppressQueueAutoAdvance = true
        isStreaming = false
        suppressQueueAutoAdvance = false
        toolCallDepth = 0
        blockedToolInvocationSignatures.removeAll()
        contentBuffer = ""
        thinkingBuffer = ""
        backgroundJobStatus = nil
    }
    
    // MARK: - Nachricht senden

    func addSystemMessage(text: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == activeSessionId }) else { return }
        let msg = ChatMessage(id: UUID(), role: "system", content: text)
        sessions[idx].messages.append(msg)
    }

    // MARK: - Nachrichten-Queue (während laufender Generierung)

    func enqueueMessage(text: String, imageBase64: String? = nil) {
        queuedMessages.append(QueuedMessage(text: text, imageBase64: imageBase64, sessionId: activeSessionId))
    }

    func removeQueuedMessage(id: UUID) {
        queuedMessages.removeAll { $0.id == id }
    }

    func sendNextQueuedMessageIfAny() {
        // Nur Nachrichten des gerade offenen Chats nachreichen – sonst landet eine Frage im falschen Chat.
        guard let i = queuedMessages.firstIndex(where: { $0.sessionId == nil || $0.sessionId == activeSessionId }) else { return }
        let next = queuedMessages.remove(at: i)
        sendMessage(text: next.text, imageBase64: next.imageBase64)
    }

    func sendMessage(text: String, imageBase64: String? = nil, displayText: String? = nil) {
        // YouTube-URL als komplette Nachricht → Transkript als Dokument importieren (Phase H).
        // Nur wenn der Text NUR aus dem Link besteht – Links mitten in Fragen gehen normal raus.
        if imageBase64 == nil, let youTube = Self.youTubeURL(in: text) {
            importYouTubeTranscript(from: youTube)
            return
        }
        toolCallDepth = 0
        blockedToolInvocationSignatures.removeAll()
        isUsingFallback = false
        guard let idx = sessions.firstIndex(where: { $0.id == activeSessionId }) else { return }
        if sessions[idx].messages.isEmpty { sessions[idx].title = String((displayText ?? text).prefix(40)) }

        let userMsgId = UUID()
        let imgID = imageBase64 != nil ? UUID() : nil
        var userMsg = ChatMessage(id: userMsgId, role: "user", content: text, imageBase64: imageBase64, imageID: imgID)
        userMsg.displayText = displayText
        sessions[idx].messages.append(userMsg)

        // Bild-zu-Text-Job hinter die aktuelle Antwort hängen (Audit M11): Vorher startete er
        // SOFORT parallel zum Antwort-Stream und konkurrierte dabei um Modell-Kapazität – bei
        // einem einzelnen, lokal geladenen Modell kontaminiert das die Generierung der Antwort,
        // die der Nutzer gerade liest. waitUntilIdle() hängt ihn hinter das Stream-Ende; die Zeit
        // bis zum Einfrieren (erst beim nächsten Senden) reicht in der Praxis weiterhin locker aus.
        if autoImageToTextEnabled, let b64 = imageBase64 {
            // Session-ID VOR dem await festhalten: Der Index ist nach dem Warten nicht mehr
            // gültig, wenn inzwischen ein Chat gelöscht/archiviert wurde (Audit 2026-10-12, H4).
            let sessionId = sessions[idx].id
            Task {
                await waitUntilIdle()
                guard !Task.isCancelled else { return }
                await describeImage(sessionId: sessionId, messageId: userMsgId, base64: b64)
            }
        }

        // Jede Nachricht, die NICHT mehr die aktuell hervorgehobene (letzte) ist, wird für ihren
        // Bildkontext ein für alle Mal eingefroren – siehe ChatMessage.frozenImageContext für die
        // Begründung (KV-Cache-Stabilität: ein sich änderndes Prompt-Präfix invalidiert bei
        // llama.cpp-basierten Servern den kompletten Cache ab dieser Stelle).
        freezeImageContextForOlderMessages(sessionIdx: idx, excluding: userMsgId)

        guard let profile = activeProfile else {
            addSystemMessage(text: "Kein aktives Endpunkt-Profil konfiguriert – bitte in den Einstellungen anlegen.")
            return
        }
        beginResponse(inSession: idx, profile: profile)
    }

    // MARK: - Retry & Rollback (Fehler-UX)

    /// Maximale automatische Verbindungsversuche nach einem Abbruch, bevor Fallback bzw.
    /// die Fehler-Karte greifen.
    static let maxConnectionRetries = 2

    /// Wiederholt eine fehlgeschlagene Antwort-Runde komplett neu: verwirft die gescheiterte
    /// Antwort (inkl. Teilinhalt und Fehler) und startet den Stream zur selben User-Nachricht
    /// mit frischem Payload (fehlgeschlagene Runden überspringen).
    func retryFailedExchange(assistantMessageId: UUID) {
        guard !isStreaming else { return }
        guard let idx = sessions.firstIndex(where: { $0.id == activeSessionId }),
              let aIdx = sessions[idx].messages.firstIndex(where: { $0.id == assistantMessageId }),
              aIdx >= 1,
              sessions[idx].messages[aIdx - 1].role == "user" else { return }

        // Gescheiterte Antwort verwerfen – die User-Nachricht bleibt als neue Basis.
        sessions[idx].messages.removeSubrange(aIdx...)
        toolCallDepth = 0
        blockedToolInvocationSignatures.removeAll()
        isUsingFallback = false
        guard let profile = activeProfile else {
            addSystemMessage(text: "Kein aktives Endpunkt-Profil konfiguriert – bitte in den Einstellungen anlegen.")
            return
        }
        beginResponse(inSession: idx, profile: profile)
    }

    /// Rollback einer fehlgeschlagenen Runde: Antwort UND User-Nachricht werden entfernt,
    /// der User-Text wird zurückgegeben (landet bearbeitbar im Eingabefeld).
    @discardableResult
    func rollbackFailedExchange(assistantMessageId: UUID) -> String? {
        guard !isStreaming else { return nil }
        guard let idx = sessions.firstIndex(where: { $0.id == activeSessionId }),
              let aIdx = sessions[idx].messages.firstIndex(where: { $0.id == assistantMessageId }),
              aIdx >= 1,
              sessions[idx].messages[aIdx - 1].role == "user" else { return nil }
        let text = sessions[idx].messages[aIdx - 1].content
        sessions[idx].messages.removeSubrange((aIdx - 1)...)
        return text
    }

    /// Setzt den Chat ab einer User-Nachricht zurück („zu einem Punkt zurückspringen"): Die
    /// Nachricht und alles danach wird entfernt, der Text landet bearbeitbar im Eingabefeld.
    /// Während einer laufenden Generierung deaktiviert (liefert nil).
    @discardableResult
    func truncateFromUserMessage(id: UUID) -> String? {
        guard !isStreaming else { return nil }
        guard let idx = sessions.firstIndex(where: { $0.id == activeSessionId }),
              let uIdx = sessions[idx].messages.firstIndex(where: { $0.id == id }),
              sessions[idx].messages[uIdx].role == "user" else { return nil }
        let text = sessions[idx].messages[uIdx].content
        sessions[idx].messages.removeSubrange(uIdx...)
        return text
    }

    /// Gemeinsame Antwort-Startlogik (Fehler-UX-Refaktor): Assistant-Platzhalter anlegen,
    /// Payload aus der Historie bauen, ggf. das LM-Studio-Modell laden und den Stream starten.
    /// Wird von sendMessage UND retryFailedExchange genutzt – identischer Payload-Aufbau.
    // MARK: - Document Attachment Handling
    func addDocument(url: URL) {
        guard let idx = sessions.firstIndex(where: { $0.id == activeSessionId }) else { return }
        
        let attachment = DocumentAttachment(url: url, status: .queued)
        let docMsgId = UUID()
        let docMsg = ChatMessage(id: docMsgId, role: "document", content: "", documentAttachment: attachment)
        
        sessions[idx].messages.append(docMsg)
        
        // Asynchron starten
        DocumentProcessor.shared.processDocument(url: url, documentId: docMsgId, viewModel: self, detailLevel: imageExtractionDetail)
    }
    
    // Call this from DocumentProcessor to update the status
    func updateDocument(id: UUID, status: AttachmentStatus, progress: Double, statusText: String, extractedText: String, images: [String] = [], previewImageBase64: String? = nil) {
        Task { @MainActor in
            // Vorher: Guard auf die AKTIVE Session – wechselt der Nutzer während der
            // Dokumentverarbeitung den Chat, wurde das Ergebnis still verworfen. Jetzt wird
            // die Nachricht in jeder aktiven Session gesucht.
            guard let sessionIdx = sessions.firstIndex(where: { session in
                    session.messages.contains(where: { $0.id == id })
                 }),
                 let msgIdx = sessions[sessionIdx].messages.firstIndex(where: { $0.id == id }),
                 var attachment = sessions[sessionIdx].messages[msgIdx].documentAttachment else { return }

            attachment.status = status
            attachment.progress = progress
            attachment.progressText = statusText
            if !extractedText.isEmpty {
                attachment.extractedText = extractedText
            }
            if !images.isEmpty {
                attachment.extractedImagePaths = images
            }
            // Live-Vorschau des Bildes, das gerade beschrieben wird (siehe DocumentBadgeView) –
            // wird bei Abschluss/Fehler automatisch geleert statt für immer stehen zu bleiben.
            if status == .completed || status == .failed {
                attachment.currentPreviewImageBase64 = nil
            } else if let previewImageBase64 {
                attachment.currentPreviewImageBase64 = previewImageBase64
            }

            sessions[sessionIdx].messages[msgIdx].documentAttachment = attachment
            // Perf-Audit K3: Ein abgeschlossenes Dokument ist einer der größten Kontext-Sprünge
            // – der Kompakt-Hinweis muss sofort aktualisiert werden, nicht erst nach der
            // nächsten (dann evtl. schon am Kontextfenster scheiternden) Antwort.
            if status == .completed {
                refreshCompactionHint()
            }
        }
    }

}
