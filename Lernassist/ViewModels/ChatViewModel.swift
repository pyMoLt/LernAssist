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
    private var heldMainModel: (instanceId: String, modelId: String, baseURL: String, apiKey: String)?

    var activeProfile: EndpointProfile? {
        profiles.first(where: { $0.id == activeProfileID }) ?? profiles.first
    }

    private var currentTask: URLSessionDataTask?
    private var currentSession: URLSession?  // muss retained werden, sonst vorzeitiger Deallocate
    /// Generations-Token des aktiven Antwort-Durchlaufs (Audit H2/H3): Jede logische Antwort-Runde
    /// bekommt eine neue UUID, cancelStreaming() rotiert sie. Verspätet eintreffende Callbacks
    /// (Retry nach 1,5 s, Fallback nach Sekunden dauerndem LM-Studio-Modellladen, cancelter
    /// Tool-Task) prüfen gegen dieses Token – sie dürfen den Zustand eines bereits danach
    /// gestarteten neuen Durchlaufs nicht mehr anfassen.
    private var streamGeneration = UUID()
    /// Geplanter Retry-/Fallback-Stream (Audit H2): als Task-Handle gespeichert, damit
    /// cancelStreaming() ihn stoppen kann – der frühere DispatchQueue.asyncAfter lief nach dem
    /// Nutzer-Abbruch trotzdem aus und startete heimlich einen neuen Stream.
    private var pendingStreamRetryTask: Task<Void, Never>?
    /// Unterdrückt das automatische Nachreichen der nächsten Queue-Nachricht (Audit M1/M4): Nach
    /// Nutzer-Abbruch oder gescheitertem Runden-Start darf keine Folgenachricht automatisch gegen
    /// denselben kaputten Endpunkt gesendet werden. Normal beendete Runden feuern weiter.
    private var suppressQueueAutoAdvance = false
    /// IDs des laufenden Streams – erlaubt cancelStreaming(), gepufferte Chunks vor dem Abbruch
    /// noch in die Nachricht zu schreiben, damit bereits gestreamter Text nicht verloren geht.
    private var currentStreamIds: (sessionId: UUID, targetMsgId: UUID)?
    /// Task, der gerade Tool-Results einsammelt und den Folge-Stream startet (siehe handleFinished).
    /// Muss von cancelStreaming() mit abgebrochen werden – sonst startete er nach dem Abbruch
    /// heimlich einen neuen Stream, während die UI bereits "idle" zeigte.
    private var toolContinuationTask: Task<Void, Never>?
    /// Verhindert endlose Tool-Calling-Rekursion. Der Wert bleibt in den Settings begrenzt,
    /// damit ein fehlerhafter Server/Prompt den Turn nicht unbegrenzt offen hält.
    private var toolCallDepth = 0
    /// Signaturen fehlgeschlagener Tool-Aufrufe im aktuellen Nutzer-Turn. Ein identischer
    /// Aufruf wird nach dem ersten Fehler nicht nochmals ausgeführt: Das Modell erhält stattdessen
    /// ein sichtbares Ergebnis und kann nur mit geänderten Argumenten sinnvoll iterieren. Dadurch
    /// wird ein wiederholter Python-/Terminal-Fehler zu einer kurzen Korrekturschleife statt zu
    /// einer Serie identischer Tool-Aufrufe.
    private var blockedToolInvocationSignatures: Set<String> = []
    /// Harte Obergrenze für parallele Calls in einer Modellrunde. Zusammen mit dem einstellbaren
    /// Rundenlimit bleibt damit auch ein fehlerhaftes Modell bei maximal 4 × maxToolRounds
    /// logischen Tool-Aufrufen pro Nutzer-Turn.
    private static let maxToolCallsPerRound = 4
    /// Verhindert doppelte gleichzeitige Hintergrund-Jobs (Phase 7C) pro Session/Nachricht.
    private var titlingInProgress: Set<UUID> = []
    private var describingImages: Set<UUID> = []

    // Performance: Throttling für Streaming-Updates
    private var contentBuffer = ""
    private var thinkingBuffer = ""
    private var updateTimer: AnyCancellable?

    // Client-seitige TPS-Messung (Fallback wenn Server keine Tok/s liefert)
    private var streamStartTime: Date?
    private var firstTokenTime: Date?

    // Persistenz: Autosave & Termination-Flush
    private var autosaveCancellable: AnyCancellable?
    /// Persistenz-Audit: Debounce-Autosave für ALLE Nicht-Profil-Einstellungen (siehe
    /// setupAutosave – vorher waren sie nur per „Fertig“-Klick oder beim App-Beenden gesichert).
    private var settingsAutosaveCancellable: AnyCancellable?
    private var activeSessionCancellable: AnyCancellable?
    private var profilesAutosaveCancellable: AnyCancellable?
    private var lastAutosavedActiveId: UUID?
    private var terminationObserver: Any?
    private var themeCancellable: AnyCancellable?
    private var contextWindowCancellable: AnyCancellable?

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
                if await manager.isLMStudioLocal(profile: profile) {
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
    private func changedSignal<P: Publisher>(_ publisher: P) -> AnyPublisher<Void, Never> where P.Failure == Never {
        publisher.dropFirst().map { _ in () }.eraseToAnyPublisher()
    }

    /// Speichert Änderungen an `sessions` gedrosselt (1s nach der letzten Änderung), damit
    /// Streaming (mehrere Content-Updates pro Sekunde) nicht bei jedem Zeichen aufs Dateisystem
    /// schreibt. Ein sofortiger Flush erfolgt zusätzlich beim Beenden der App (s. u.).
    private func setupAutosave() {
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

    private func setupTerminationFlush() {
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

    // MARK: - Custom Prompts

    /// Gibt den aktiven Prompt für den gewählten Lernmodus zurück (Custom > Default)
    func prompt(for style: LearningStyle) -> String {
        let custom = customPrompts[style.rawValue] ?? ""
        return custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? style.defaultPrompt
            : custom
    }

    private func currentPersistedSettings() -> PersistedSettings {
        let hkMap = Dictionary(uniqueKeysWithValues: hotkeys.map { ($0.key.rawValue, $0.value) })
        return PersistedSettings(
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
            youtubeSubtitleLanguage: youtubeSubtitleLanguage,
            youtubeTranscriptCharLimit: youtubeTranscriptCharLimit,
            customArchiveFolders: customArchiveFolders
        )
    }

    func saveSettings() {
        SettingsStore.shared.save(currentPersistedSettings())
    }

    private func loadSettings() {
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
            guard let models = try? await EndpointManager.fetchModels(for: profile) else { return }
            guard let match = models.first(where: { $0.id == profile.model }), let ctx = match.contextWindow else { return }
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
        // War vorher eine eigene, provider-unabhängige URL-Konstruktion (blindes Anhängen von
        // "/models"), die für Ollama (dessen Modell-Liste unter /api/tags statt /models liegt)
        // immer fehlschlug – ein funktionierender Ollama-Server wurde als "nicht erreichbar"
        // gemeldet. Nutzt jetzt dieselbe provider-bewusste URL-Logik wie `fetchModels`.
        guard let url = EndpointManager.modelsURL(for: profile) else { return false }

        var request = URLRequest(url: url, timeoutInterval: 5.0)
        request.httpMethod = "GET"
        if !profile.apiKey.isEmpty {
            request.setValue("Bearer \(profile.apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return true
            }
        } catch {}
        return false
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
        currentTask?.cancel()
        currentTask = nil
        currentSession?.invalidateAndCancel()
        currentSession = nil
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
    
    /// Modellname für einen Request: bei Hintergrund-Jobs mit gesetztem `backgroundJobModel` wird
    /// dieses kleinere/schnellere Modell genutzt (spart RAM ggü. einem zweiten vollen Modell, da
    /// LM Studio/llama.cpp Modelle bei Bedarf ein-/auswechseln statt beide gleichzeitig zu laden),
    /// sonst das reguläre Chat-Modell des Profils.
    private static func effectiveModel(for profile: EndpointProfile, useBackgroundJobModel: Bool) -> String {
        guard useBackgroundJobModel else { return profile.model }
        let trimmed = profile.backgroundJobModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? profile.model : trimmed
    }

    // MARK: - Invisible Prompts für Hintergrund-Generierung (Quiz/Flashcards/Verify)
    
    /// Sendet einen Prompt ohne ihn in der Session zu speichern und gibt die gesammelte Antwort zurück.
    /// Bettet Bilder aus `context` (z.B. Screenshots im Chatverlauf) als Vision-Content ein, statt sie
    /// stillschweigend zu verwerfen – sonst "sieht" z.B. das Quiz/die Karteikarten nichts von den
    /// Screenshots, obwohl der Chat-Kontext primär aus Bildern bestehen kann (Kernfunktion der App).
    /// - Parameter useBackgroundJobModel: true für reine Hintergrund-Jobs (Titel, Zusammenfassung) –
    ///   nutzt dann `profile.backgroundJobModel` (falls gesetzt) statt des vollen Chat-Modells und
    ///   wendet bei aktivem `disableThinkingForBackgroundJobs` die Best-effort-"No Thinking"-
    ///   Modifikatoren an. Bewusst NICHT für Quiz/Karteikarten-Generierung genutzt, da dort die
    ///   inhaltliche Qualität (korrekte Fragen/Antworten) wichtiger ist als Geschwindigkeit.
    func sendInvisiblePrompt(_ prompt: String, context: [ChatMessage],
                             imageBase64: String? = nil,
                             useBackgroundJobModel: Bool = false) async -> String? {
        guard let profile = activeProfile,
              let url = EndpointManager.chatCompletionsURL(for: profile) else {
            AppLog.chat.error("sendInvisiblePrompt: kein Endpunkt konfiguriert")
            return nil
        }

        let applyNoThink = useBackgroundJobModel && disableThinkingForBackgroundJobs
        let effectivePrompt = applyNoThink ? prompt + "\n/no_think" : prompt

        var messages: [[String: Any]] = context.map { msg in
            if let b64 = msg.imageBase64 {
                return EndpointManager.userImageMessage(text: msg.content, base64: b64, provider: profile.provider)
            }
            return ["role": msg.role, "content": msg.content]
        }
        if let b64 = imageBase64 {
            messages.append(EndpointManager.userImageMessage(text: effectivePrompt, base64: b64, provider: profile.provider))
        } else {
            messages.append(["role": "user", "content": effectivePrompt])
        }

        let modelName = Self.effectiveModel(for: profile, useBackgroundJobModel: useBackgroundJobModel)
        var payload: [String: Any] = [
            "model": modelName,
            "messages": messages,
            "stream": false
        ]
        if applyNoThink { payload = EndpointManager.disableThinkingModifiers(payload) }
        payload = EndpointManager.adaptPayload(payload, for: profile)

        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            AppLog.chat.error("sendInvisiblePrompt: Payload-Serialisierung fehlgeschlagen")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        EndpointManager.authHeaders(for: profile).forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = data

        // LM Studio: Hintergrundmodell sicherstellen + nach Job wieder freigeben
        let manager = LMStudioModelManager.shared
        var lmsInstanceId: String?
        if useBackgroundJobModel && manager.isLMStudioLocal(profile: profile) {
            let lmsModelId = manager.effectiveLMStudioModelId(profile: profile, useBackground: true)
            lmsInstanceId = await manager.acquire(modelId: lmsModelId, baseURL: profile.baseURL, apiKey: profile.apiKey)
        }
        defer {
            if let instanceId = lmsInstanceId {
                Task {
                    let lmsModelId = manager.effectiveLMStudioModelId(profile: profile, useBackground: true)
                    await manager.release(instanceId: instanceId, modelId: lmsModelId, baseURL: profile.baseURL, apiKey: profile.apiKey)
                }
            }
        }

        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            // Früher wurden HTTP-Fehler (z.B. 401) still als "unbekannter Fehler" behandelt und
            // der Fehler-Text landete als "Antwort" beim Aufrufer – z.B. als Chat-Titel.
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                AppLog.chat.error("sendInvisiblePrompt: HTTP-Fehler \(code) von \(profile.name)")
                return nil
            }
            if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let content = EndpointManager.extractResponseContent(json) {
                return content
            }
            AppLog.chat.error("sendInvisiblePrompt: Antwort konnte nicht verarbeitet werden")
            return nil
        } catch {
            AppLog.chat.error("sendInvisiblePrompt: Netzwerkfehler \(error.localizedDescription)")
            return nil
        }
    }

    /// Zwingt das Modell, seine letzte Antwort aktiv per Websuche zu überprüfen.
    /// Aufrufbar über den "Verifizieren"-Button an einer Nachricht oder den `/verify`-Befehl.
    func verifyLastResponse() {
        guard let session = activeSession,
              session.messages.last(where: { $0.role == "assistant" && !$0.content.isEmpty }) != nil
        else {
            addSystemMessage(text: "Nichts zu verifizieren – es gibt noch keine Antwort in diesem Chat.")
            return
        }

        let notice = searchEnabled ? "" :
            "\n\n(Hinweis: Die Websuche ist aktuell deaktiviert – aktiviere sie in den Einstellungen für eine echte Verifikation.)"
        sendMessage(text: """
            Verifiziere deine letzte Antwort aktiv per Websuche. Gehe so vor:
            1. Identifiziere die zentralen, überprüfbaren Fakten-Aussagen in deiner letzten Antwort.
            2. Suche gezielt nach jeder Aussage, um sie zu bestätigen oder zu widerlegen.
            3. Gib für jede Aussage an: ✅ Bestätigt / ⚠️ Teilweise / ❌ Widerlegt / ❓ Nicht auffindbar – jeweils mit Quelle.
            4. Fasse am Ende zusammen, ob deine vorherige Antwort insgesamt verlässlich war.\(notice)
            """)
    }

    // MARK: - Nachricht senden

    func addSystemMessage(text: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == activeSessionId }) else { return }
        let msg = ChatMessage(id: UUID(), role: "system", content: text)
        sessions[idx].messages.append(msg)
    }

    // MARK: - Nachrichten-Queue (während laufender Generierung)

    func enqueueMessage(text: String, imageBase64: String? = nil) {
        queuedMessages.append(QueuedMessage(text: text, imageBase64: imageBase64))
    }

    func removeQueuedMessage(id: UUID) {
        queuedMessages.removeAll { $0.id == id }
    }

    private func sendNextQueuedMessageIfAny() {
        guard !queuedMessages.isEmpty else { return }
        let next = queuedMessages.removeFirst()
        sendMessage(text: next.text, imageBase64: next.imageBase64)
    }

    func sendMessage(text: String, imageBase64: String? = nil) {
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
        if sessions[idx].messages.isEmpty { sessions[idx].title = String(text.prefix(40)) }

        let userMsgId = UUID()
        let imgID = imageBase64 != nil ? UUID() : nil
        let userMsg = ChatMessage(id: userMsgId, role: "user", content: text, imageBase64: imageBase64, imageID: imgID)
        sessions[idx].messages.append(userMsg)

        // Bild-zu-Text-Job hinter die aktuelle Antwort hängen (Audit M11): Vorher startete er
        // SOFORT parallel zum Antwort-Stream und konkurrierte dabei um Modell-Kapazität – bei
        // einem einzelnen, lokal geladenen Modell kontaminiert das die Generierung der Antwort,
        // die der Nutzer gerade liest. waitUntilIdle() hängt ihn hinter das Stream-Ende; die Zeit
        // bis zum Einfrieren (erst beim nächsten Senden) reicht in der Praxis weiterhin locker aus.
        if autoImageToTextEnabled, let b64 = imageBase64 {
            Task {
                await waitUntilIdle()
                guard !Task.isCancelled else { return }
                await describeImage(sessionId: sessions[idx].id, messageId: userMsgId, base64: b64)
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
    private static let maxConnectionRetries = 2

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
    private func beginResponse(inSession idx: Int, profile: EndpointProfile) {
        let assistantMsgId = UUID()
        sessions[idx].messages.append(ChatMessage(id: assistantMsgId, role: "assistant", content: ""))
        // Neue logische Antwort-Runde → neue Stream-Generation (Audit H2/H3).
        streamGeneration = UUID()
        let generation = streamGeneration
        isStreaming = true

        guard let url = EndpointManager.chatCompletionsURL(for: profile) else {
            // Audit M1: Ungültige Endpoint-URL darf keine leere Bubble ohne Fehlermeldung
            // hinterlassen und nicht die nächste Queue-Nachricht automatisch gegen denselben
            // kaputten Endpunkt feuern.
            failCurrentExchange(sessionId: sessions[idx].id, targetMsgId: assistantMsgId,
                                message: "Ungültige Endpunkt-URL im Profil „\(profile.name)“. Bitte die URL in den Einstellungen prüfen.")
            return
        }
        // System-Prompt: Basis + Registry-Tool-Erweiterung (nur für aktive Tools)
        // Wichtig für KV-Cache: System → Tools → History → User-Nachricht (stabile Reihenfolge)
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .none // Keine Uhrzeit, um ständige KV-Cache-Invalidierung (jede Minute) zu verhindern
        dateFormatter.locale = Locale(identifier: "de_DE")
        let dateString = dateFormatter.string(from: Date())
        let datePrompt = "\n[System: Das aktuelle Datum ist \(dateString). Berücksichtige dies bei zeitlichen Einordnungen.]\n"
        
        let systemContent = prompt(for: learningStyle) + datePrompt + ToolRegistry.shared.systemPromptAddition
        // Hervorgehobene User-Nachricht (Bild-Kontext) = die letzte vor dem Platzhalter.
        let highlightedUserMsgId = sessions[idx].messages.dropLast().last(where: { $0.role == "user" })?.id ?? UUID()

        var messages: [[String: Any]] = [["role": "system", "content": systemContent]]
        for msg in sessions[idx].messages.dropLast() {
            if msg.role == "document" {
                if let attachment = msg.documentAttachment, attachment.status == .completed {
                    let externalContent = """
                    <EXTERNAL_DOCUMENT filename="\(attachment.url.lastPathComponent)">
                    \(attachment.extractedText)
                    </EXTERNAL_DOCUMENT>
                    """
                    messages.append(["role": "system", "content": externalContent])
                }
            } else if msg.role == "system" {
                // Reine UI-Hinweise („Befehl ausgeführt", /help-Text, Export-Meldungen, ...)
                // gehören NICHT in den API-Payload – sie verschmutzen sonst den Kontext.
                continue
            } else if msg.errorMessage != nil {
                // Fehlgeschlagene Antwortrunden (Teilantwort + Fehler) gehören NICHT in den
                // Kontext – sonst antwortet das Modell auf fragmentierte Halbsätze.
                continue
            } else {
                messages.append(contentsOf: apiMessages(for: msg, highlightedUserMsgId: highlightedUserMsgId, provider: profile.provider))
            }
        }

        // LM Studio: Hauptmodell vorab laden, falls nötig, BEVOR der Stream startet.
        // Alle anderen Provider (OpenAI, Ollama, Groq, …) überspringen diesen Schritt.
        let sessionIdForStream = sessions[idx].id
        Task {
            let manager = LMStudioModelManager.shared
            if await manager.isLMStudioLocal(profile: profile) {
                let lmsModelId = await manager.effectiveLMStudioModelId(profile: profile, useBackground: false)

                // Falls bereits ein ANDERES Hauptmodell gehalten wird (Profil- oder Modellwechsel
                // seit der letzten Nachricht), dieses zuerst freigeben – sonst würde beim
                // Ausprobieren mehrerer Modelle jedes davon dauerhaft im RAM bleiben, da für das
                // Hauptmodell bewusst kein automatischer Idle-Unload während laufender Nutzung
                // greift (siehe heldMainModel-Kommentar).
                if let held = self.heldMainModel, held.modelId != lmsModelId {
                    await manager.release(instanceId: held.instanceId, modelId: held.modelId,
                                           baseURL: held.baseURL, apiKey: held.apiKey)
                    await MainActor.run { self.heldMainModel = nil }
                }

                if self.heldMainModel == nil {
                    await MainActor.run { self.lmStudioStatus = .loading(lmsModelId) }
                    let instanceId = await manager.acquire(modelId: lmsModelId, baseURL: profile.baseURL, apiKey: profile.apiKey)
                    await MainActor.run {
                        if let instanceId {
                            self.lmStudioStatus = .loaded
                            self.heldMainModel = (instanceId, lmsModelId, profile.baseURL, profile.apiKey)
                        } else {
                            // Modell konnte nicht geladen werden – trotzdem versuchen (LMS lädt evtl. selbst)
                            self.lmStudioStatus = .unreachable
                        }
                    }
                } else {
                    await MainActor.run { self.lmStudioStatus = .loaded }
                }
            }
            await MainActor.run {
                self.startStream(profile: profile, url: url, messages: messages, targetMsgId: assistantMsgId,
                                 sessionId: sessionIdForStream, generation: generation)
            }
        }
    }
    
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

    // MARK: - Streaming starten (wiederverwendbar für Tool-Continuation & Fallback-Retry)

    /// Fallback-Stream (Remote↔Lokal-Audit): Startet den Retry mit dem Fallback-Profil – aber
    /// lädt für LM-Studio-Fallback-Profile zuerst deren Modell, exakt mit derselben Acquire/Release-
    /// Semantik wie sendMessage(). Ohne diesen Schritt würde ein Fallback von einem Remote-Endpunkt
    /// auf ein lokales LM-Studio-Profil mit einem nicht geladenen Modell laufen und an LM Studios
    /// "no model loaded"-404 scheitern (auch der Fallback-Versuch ist dann bereits verbraucht).
    /// Für Nicht-LM-Studio-Fallback-Profile (Ollama, Remote) läuft der Stream direkt an.
    private func startFallbackStream(profile: EndpointProfile, url: URL, messages: [[String: Any]],
                                      targetMsgId: UUID, sessionId: UUID, generation: UUID) {
        // Audit H2: Auch der Fallback-Stream (evtl. nach Sekunden dauerndem LM-Studio-
        // Modell-Laden) läuft als cancelbarer Task mit Generation-Guard – cancelStreaming()
        // während des Ladens verhindert so den heimlichen Stream-Start hinterher.
        pendingStreamRetryTask?.cancel()
        pendingStreamRetryTask = Task { [weak self] in
            guard let self else { return }
            let manager = LMStudioModelManager.shared
            if await manager.isLMStudioLocal(profile: profile) {
                let lmsModelId = await manager.effectiveLMStudioModelId(profile: profile, useBackground: false)
                // Falls ein ANDERES Hauptmodell gehalten wird (z.B. Remote-Failover von einem
                // LM-Studio-Primärprofil): sauber wechseln, sonst bliebe jedes dauerhaft im RAM.
                if let held = self.heldMainModel, held.modelId != lmsModelId {
                    await manager.release(instanceId: held.instanceId, modelId: held.modelId,
                                           baseURL: held.baseURL, apiKey: held.apiKey)
                    await MainActor.run { self.heldMainModel = nil }
                }
                if self.heldMainModel == nil {
                    await MainActor.run { self.lmStudioStatus = .loading(lmsModelId) }
                    let instanceId = await manager.acquire(modelId: lmsModelId, baseURL: profile.baseURL, apiKey: profile.apiKey)
                    await MainActor.run {
                        if let instanceId {
                            self.lmStudioStatus = .loaded
                            self.heldMainModel = (instanceId, lmsModelId, profile.baseURL, profile.apiKey)
                        } else {
                            self.lmStudioStatus = .unreachable
                        }
                    }
                } else {
                    await MainActor.run { self.lmStudioStatus = .loaded }
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, generation == self.streamGeneration else { return }
                self.startStream(profile: profile, url: url, messages: messages,
                                 targetMsgId: targetMsgId, sessionId: sessionId,
                                 isFallbackAttempt: true, generation: generation)
            }
        }
    }

    private func startStream(profile: EndpointProfile, url: URL, messages: [[String: Any]],
                             targetMsgId: UUID, sessionId: UUID,
                             isFallbackAttempt: Bool = false, autoRetryCount: Int = 0,
                             generation: UUID? = nil) {
        // Audit H2: Ein verspätet eintreffender Stream-Start (Retry nach Nutzer-Abbruch,
        // Fallback nach Sekunden dauerndem LM-Studio-Modellladen) gehört zu einer alten
        // Generation und darf weder den aktuellen Stream killen noch einen neuen starten.
        let gen = generation ?? streamGeneration
        guard gen == streamGeneration else { return }

        // Alte Session aufräumen um Verbindungs-Limit-Deadlocks zu verhindern
        currentTask?.cancel()
        currentSession?.invalidateAndCancel()
        currentStreamIds = (sessionId, targetMsgId)

        // Fallback-/Auto-Retry sauber bei null starten (Remote↔Lokal-Audit + Fehler-UX):
        // Scheitert ein Versuch MITTEN im Stream (z.B. Verbindungsabbruch nach bereits
        // geflushten Tokens), enthält die Ziel-Nachricht schon Teiltext des gescheiterten
        // Versuchs – und in den Buffern können ungeflushte Reste liegen. Ohne Reset würde
        // die nächste Antwort an die Teilantwort angehängt (gemischter, unsinniger Text).
        if isFallbackAttempt || autoRetryCount > 0 {
            contentBuffer = ""
            thinkingBuffer = ""
            if let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
               let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == targetMsgId }) {
                sessions[sIdx].messages[mIdx].content = ""
                sessions[sIdx].messages[mIdx].thinking = nil
                sessions[sIdx].messages[mIdx].toolCalls = nil
            }
        }

        // Client-Timer und Metriken für die neue Antwort-Runde zurücksetzen – sonst zeigte
        // die MetricsBar bis zum ersten Metrik-Chunk die Werte der vorigen Antwort.
        streamStartTime = Date()
        firstTokenTime = nil
        currentMetrics = .empty

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        EndpointManager.authHeaders(for: profile).forEach { request.setValue($1, forHTTPHeaderField: $0) }

        // Kontext-Budget vor dem Serialisieren anwenden. Vorher wurde zwar `effectiveMessages`
        // berechnet, die schon gebaute HTTP-Body enthielt aber weiterhin den ungekürzten Verlauf.
        let effectiveMessages = Self.trimmedToContextBudget(
            messages,
            contextWindow: profile.contextSizeOverride,
            maxTokens: profile.params.maxTokens
        )

        var payload: [String: Any] = ["model": profile.model, "messages": effectiveMessages, "stream": true]
        // Ohne dieses Flag liefert KEIN OpenAI-kompatibler Server (auch llama.cpp/llama-server
        // nicht) das usage-Objekt im letzten SSE-Chunk – das war vermutlich der Hauptgrund, warum
        // Tok/s-Metriken bisher nie ankamen, unabhängig vom Endpunkt. Unkritisch für Server, die
        // das Feld nicht kennen (unbekannte JSON-Keys werden ignoriert).
        payload["stream_options"] = ["include_usage": true]
        let params = profile.params
        if let t = params.temperature { payload["temperature"] = t }
        if let p = params.topP { payload["top_p"] = p }
        if let k = params.topK { payload["top_k"] = k }
        if let m = params.maxTokens { payload["max_tokens"] = m }
        if let pp = params.presencePenalty { payload["presence_penalty"] = pp }
        if let fp = params.frequencyPenalty { payload["frequency_penalty"] = fp }
        if let seed = params.seed { payload["seed"] = seed }
        if let stop = params.stop, !stop.isEmpty { payload["stop"] = stop }
        // Tool-Schemas aus der Registry (nur aktive Tools, stabile Reihenfolge für KV-Cache)
        let activeSchemas = ToolRegistry.shared.schemas
        if !activeSchemas.isEmpty {
            payload["tools"] = activeSchemas
            payload["tool_choice"] = "auto"
        }

        payload = EndpointManager.adaptPayload(payload, for: profile)

        guard let requestData = try? JSONSerialization.data(withJSONObject: payload) else {
            AppLog.chat.error("Payload-Serialisierung fehlgeschlagen")
            // Audit M1: Auch dieser Fehlerpfad hinterlässt sonst eine leere Bubble ohne
            // Fehlermeldung und feuert die nächste Queue-Nachricht gegen denselben Endpunkt.
            failCurrentExchange(sessionId: sessionId, targetMsgId: targetMsgId,
                                message: "Interner Fehler: Die Anfrage an \(profile.name) konnte nicht aufgebaut werden (Payload-Serialisierung).")
            return
        }
        request.httpBody = requestData

        let delegate = StreamingDelegate(
            onChunk: { [weak self] chunk, type in
                DispatchQueue.main.async {
                    guard
                        let self,
                        gen == self.streamGeneration,
                        let sIdx = self.sessions.firstIndex(where: { $0.id == sessionId }),
                        self.sessions[sIdx].messages.contains(where: { $0.id == targetMsgId })
                    else { return }

                    switch type {
                    case .content:
                        self.contentBuffer += chunk
                        // Ersten Token-Zeitpunkt messen (für TTFT)
                        if self.firstTokenTime == nil {
                            self.firstTokenTime = Date()
                            if let start = self.streamStartTime {
                                self.currentMetrics.timeToFirstToken = Date().timeIntervalSince(start)
                            }
                        }
                    case .thinking:
                        self.thinkingBuffer += chunk
                    case .tool(let info):
                        // Tool Calls schicken wir direkt ans UI (sind selten genug)
                        self.updateSessionToolCall(sessionId: sessionId, messageId: targetMsgId, tool: info)
                    }
                }
            },
            onFinish: { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard gen == self.streamGeneration else { return }
                    self.updateTimer?.cancel()
                    self.updateTimer = nil
                    self.flushBuffers(sessionId: sessionId, targetMsgId: targetMsgId)

                    // Client-seitige Gesamt-TPS berechnen wenn kein server-seitiger Wert vorhanden
                    if let start = self.streamStartTime {
                        let elapsed = Date().timeIntervalSince(start)
                        self.currentMetrics.totalDuration = elapsed
                        if self.currentMetrics.tokensPerSecond == nil,
                           self.currentMetrics.completionTokens > 0,
                           elapsed > 0.1 {
                            self.currentMetrics.tokensPerSecond = Double(self.currentMetrics.completionTokens) / elapsed
                        }
                    }

                    guard let sIdx = self.sessions.firstIndex(where: { s in
                        s.messages.contains(where: { $0.id == targetMsgId })
                    }) else {
                        AppLog.chat.info("Session oder Message nach Stream-Ende nicht mehr vorhanden.")
                        self.isStreaming = false
                        return
                    }
                    self.handleFinished(profile: profile, sessionIdx: sIdx, assistantMsgId: targetMsgId,
                                        sessionId: sessionId, prevMessages: effectiveMessages)
                }
            },
            onError: { [weak self] error in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard gen == self.streamGeneration else { return }

                    // Nutzer-Abbruch: KEINE Fehlermeldung an die Antwort anhängen (früher wurde
                    // nach dem Abbruch ein irreführender "Netzwerkfehler" angehängt, obwohl der
                    // Nutzer selbst abgebrochen hat).
                    if (error as? URLError)?.code == .cancelled {
                        self.isStreaming = false
                        return
                    }

                    // Automatischer Verbindungs-Retry (Fehler-UX): Bricht die Verbindung ab
                    // (Netzwerk, Server-Neustart, Sleep/Wake), wird dieselbe Anfrage nach kurzer
                    // Pause bis zu N-mal mit frischem Start wiederholt – Teilinhalt des
                    // abgebrochenen Versuchs wird dabei zurückgesetzt. Erst danach greifen
                    // Fallback bzw. Fehler-Karte. Flüchtige 5xx (Gateway-Neustarts) zählen dazu.
                    let isTransient: Bool
                    if case EndpointManager.EndpointError.httpError(let code) = error {
                        // 429 (Rate-Limit) bewusst mit dabei: auch ein vorübergehend
                        // limitierter Remote-Endpoint verdient die kurze automatische
                        // Wiederholung, bevor der Fehler angezeigt wird.
                        isTransient = [429, 502, 503, 529].contains(code)
                    } else {
                        isTransient = EndpointManager.isConnectivityError(error)
                    }
                    if autoRetryCount < Self.maxConnectionRetries, isTransient {
                        AppLog.chat.info("Verbindung abgebrochen – automatischer Retry \(autoRetryCount + 1)/\(Self.maxConnectionRetries) in 1,5 s")
                        // Audit H2: Der Retry läuft als cancelbarer Task mit Generation-
                        // Guard statt fire-and-forget-asyncAfter – cancelStreaming() stoppt
                        // ihn zuverlässig, ein Abbruch während der 1,5 s verhindert den
                        // heimlichen Neustart.
                        pendingStreamRetryTask?.cancel()
                        pendingStreamRetryTask = Task { [weak self] in
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            guard !Task.isCancelled else { return }
                            await MainActor.run { [weak self] in
                                guard let self, gen == self.streamGeneration else { return }
                                self.startStream(profile: profile, url: url, messages: effectiveMessages,
                                                 targetMsgId: targetMsgId, sessionId: sessionId,
                                                 isFallbackAttempt: isFallbackAttempt,
                                                 autoRetryCount: autoRetryCount + 1,
                                                 generation: gen)
                            }
                        }
                        return
                    }

                    // Remote nicht erreichbar bzw. eindeutig endpunktbezogener HTTP-Fehler +
                    // Fallback-Profil konfiguriert → einmalig automatisch mit dem Fallback-Profil
                    // erneut versuchen, bevor der Fehler angezeigt wird. HTTP-Fehler wie 401/404/5xx
                    // sind der klassische "falscher Endpoint"-Fall und triggerten bisher gar keinen
                    // Fallback.
                    if !isFallbackAttempt,
                       EndpointManager.shouldAttemptFallback(error: error),
                       let fallbackID = self.fallbackProfileID,
                       let fallbackProfile = self.profiles.first(where: { $0.id == fallbackID }),
                       fallbackProfile.id != profile.id,
                       let fallbackURL = EndpointManager.chatCompletionsURL(for: fallbackProfile) {
                        AppLog.chat.info("\(profile.name, privacy: .public) fehlgeschlagen (\(error.localizedDescription, privacy: .public)) – Fallback auf \(fallbackProfile.name, privacy: .public)")
                        self.isUsingFallback = true
                        self.startFallbackStream(profile: fallbackProfile, url: fallbackURL,
                                                 messages: effectiveMessages,
                                                 targetMsgId: targetMsgId, sessionId: sessionId,
                                                 generation: gen)
                        return
                    }

                    AppLog.chat.error("Stream fehlgeschlagen: \(error.localizedDescription)")
                    guard
                        let sIdx = self.sessions.firstIndex(where: { $0.id == sessionId }),
                        let mIdx = self.sessions[sIdx].messages.firstIndex(where: { $0.id == targetMsgId })
                    else {
                        self.isStreaming = false
                        return
                    }

                    // Klare, ursachengerechte Fehlermeldung – als eigenes Feld statt im Content
                    // (Fehler-UX): Die UI zeigt sie als Fehler-Karte mit Retry-/Bearbeiten-
                    // Aktionen, der (Teil-)Inhalt bleibt unangetastet und wird beim nächsten
                    // Versand übersprungen.
                    var errorMsg: String
                    if case EndpointManager.EndpointError.httpError(let code) = error {
                        errorMsg = "HTTP-Fehler \(code) von \(profile.name). Prüfe API-Key, Modellnamen und Endpoint-URL – z.B. Modell in LM Studio geladen?"
                    } else if EndpointManager.isConnectivityError(error) && !profile.isRemote {
                        errorMsg = "\(profile.name) ist nicht erreichbar. Bitte starte LM Studio und stelle sicher, dass der Server läuft, bevor du schreibst."
                    } else {
                        errorMsg = "Netzwerkfehler: \(error.localizedDescription). Prüfe, ob \(profile.name) erreichbar ist und der Endpoint korrekt ist."
                    }
                    if isUsingFallback {
                        errorMsg += " (Antwort lief über das Fallback-Profil.)"
                    }
                    self.sessions[sIdx].messages[mIdx].errorMessage = errorMsg
                    self.isStreaming = false
                }
            },
            onMetrics: { [weak self] metrics in
                DispatchQueue.main.async { [weak self] in
                    self?.currentMetrics = metrics
                }
            },
            isNDJSON: profile.provider == .ollama
        )

        let sess = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        currentSession = sess
        currentTask = sess.dataTask(with: request)
        currentTask?.resume()
        
        // Performance-Timer: Aktualisiere das UI alle 200ms (5Hz)
        // Das gibt der Benutzeroberfläche massiv viel Zeit für Scroll-Events und Input
        updateTimer = Timer.publish(every: 0.2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.flushBuffers(sessionId: sessionId, targetMsgId: targetMsgId)
            }
    }
    
    /// Wendet gepufferte Chunks synchron an. Alle Aufrufer laufen auf dem Main-Thread
    /// (UI-Timer, onFinish, cancelStreaming) – das frühere `DispatchQueue.main.async` hier
    /// verzögerte die Anwendung nur: handleFinished las den Content, BEVOR der letzte Flush
    /// landete, und verpasste dadurch Inline-Tool-Calls im letzten Chunk.
    private func flushBuffers(sessionId: UUID, targetMsgId: UUID) {
        guard !contentBuffer.isEmpty || !thinkingBuffer.isEmpty else { return }
        let c = contentBuffer
        let t = thinkingBuffer
        contentBuffer = ""
        thinkingBuffer = ""

        guard
            let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
            let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == targetMsgId })
        else { return }

        if !c.isEmpty { sessions[sIdx].messages[mIdx].content += c }
        if !t.isEmpty {
            if sessions[sIdx].messages[mIdx].thinking == nil {
                sessions[sIdx].messages[mIdx].thinking = ""
            }
            sessions[sIdx].messages[mIdx].thinking! += t
        }
    }

    /// Akkumuliert gestreamte Tool-Call-Deltas live in der Ziel-Nachricht (läuft auf main).
    private func updateSessionToolCall(sessionId: UUID, messageId: UUID, tool: ToolCallInfo) {
        DispatchQueue.main.async { [weak self] in
            guard
                let self,
                let sIdx = self.sessions.firstIndex(where: { $0.id == sessionId }),
                let mIdx = self.sessions[sIdx].messages.firstIndex(where: { $0.id == messageId })
            else { return }
            
            if self.sessions[sIdx].messages[mIdx].toolCalls == nil {
                self.sessions[sIdx].messages[mIdx].toolCalls = []
            }
            if let tIdx = self.sessions[sIdx].messages[mIdx].toolCalls!.firstIndex(where: {
                ($0.index != nil && $0.index == tool.index) || ($0.id == tool.id && !tool.id.isEmpty)
            }) {
                // Nur Arguments akkumulieren – der Name kommt ausschließlich im ersten Delta
                // und ist bereits beim append() gesetzt worden. Nie arguments += name!
                if !tool.arguments.isEmpty {
                    self.sessions[sIdx].messages[mIdx].toolCalls![tIdx].arguments += tool.arguments
                }
            } else {
                self.sessions[sIdx].messages[mIdx].toolCalls!.append(tool)
            }
        }
    }

    // MARK: - Nach Streaming: Tool-Calls ausführen oder fertig

    private static func toolInvocationSignature(_ call: ToolCallInfo) -> String {
        "\(call.name)\u{001F}\(call.arguments)"
    }

    private func handleFinished(profile: EndpointProfile, sessionIdx: Int, assistantMsgId: UUID,
                                 sessionId: UUID, prevMessages: [[String: Any]]) {
        let configuredMaxToolRounds = min(max(maxToolRounds, 1), 12)
        guard toolCallDepth < configuredMaxToolRounds else {
            // Das Modell darf nicht in eine Endlosschleife aus Suche → Browse → neue Suche
            // geraten. Bisher blieb der letzte, bewusst NICHT mehr ausgeführte Tool-Call jedoch
            // mit `result == nil` stehen. Die UI zeigte dadurch einen Spinner, obwohl die Antwort
            // bereits beendet war (wie im gemeldeten SearXNG-Fall). Jeder offene Call erhält
            // daher ein sichtbares Endergebnis statt eines ewigen „lädt noch“.
            if sessions.indices.contains(sessionIdx),
               let mIdx = sessions[sessionIdx].messages.firstIndex(where: { $0.id == assistantMsgId }) {
                let limitMessage = "Nicht ausgeführt: Das Limit von \(configuredMaxToolRounds) aufeinanderfolgenden Tool-Runden wurde erreicht."
                if var calls = sessions[sessionIdx].messages[mIdx].toolCalls {
                    for index in calls.indices where calls[index].result == nil {
                        calls[index].result = limitMessage
                    }
                    sessions[sessionIdx].messages[mIdx].toolCalls = calls
                }
                if sessions[sessionIdx].messages[mIdx].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sessions[sessionIdx].messages[mIdx].content =
                        "Ich konnte nach mehreren Tool-Aufrufen keine brauchbare Antwort finden. Versuch's gerne mit einer präziseren Frage oder einer anderen Quelle."
                }
            }
            finishExchange(sessionId: sessionId)
            return
        }

        guard let mIdx = sessions[sessionIdx].messages.firstIndex(where: { $0.id == assistantMsgId }) else {
            finishExchange(sessionId: sessionId); return
        }

        // --- Inline-Fallback-Parser (Phase 5) ---
        // Offizielle tool_calls und Inline-Calls können bei kleinen Modellen im selben Turn
        // vorkommen. Deshalb werden Content UND Thinking immer getrennt geprüft; das Thinking
        // bleibt dabei bewusst im Thinking-Feld sichtbar/persistiert (Nutzerentscheidung), nur
        // das Tool-Markerfragment wird entfernt.
        var inlineCalls: [ToolCallParser.ParsedCall] = []
        if let thinking = sessions[sessionIdx].messages[mIdx].thinking, !thinking.isEmpty {
            let (thinkingCalls, cleanedThinking) = ToolCallParser.extractInlineCalls(from: thinking)
            if !thinkingCalls.isEmpty {
                inlineCalls.append(contentsOf: thinkingCalls)
                sessions[sessionIdx].messages[mIdx].thinking = cleanedThinking.isEmpty ? nil : cleanedThinking
            }
        }
        let (contentCalls, cleanedContent) = ToolCallParser.extractInlineCalls(
            from: sessions[sessionIdx].messages[mIdx].content)
        if !contentCalls.isEmpty {
            inlineCalls.append(contentsOf: contentCalls)
            sessions[sessionIdx].messages[mIdx].content = cleanedContent
        }

        if !inlineCalls.isEmpty {
            let existing = sessions[sessionIdx].messages[mIdx].toolCalls ?? []
            var seen = Set(existing.map { "\($0.name)\u{001F}\($0.arguments)" })
            let syntheticCalls = inlineCalls.compactMap { parsed -> ToolCallInfo? in
                let key = "\(parsed.name)\u{001F}\(parsed.arguments)"
                guard seen.insert(key).inserted else { return nil }
                return ToolCallInfo(id: "inline_\(UUID().uuidString.prefix(8))",
                                    index: nil, name: parsed.name, arguments: parsed.arguments)
            }
            sessions[sessionIdx].messages[mIdx].toolCalls = existing + syntheticCalls
        }

        guard let receivedToolCalls = sessions[sessionIdx].messages[mIdx].toolCalls,
              !receivedToolCalls.isEmpty else {
            finishExchange(sessionId: sessionId); return
        }

        // OpenAI verlangt, dass assistant.tool_calls[].id und tool.tool_call_id exakt
        // übereinstimmen. Ollama und einige kompatible Server lassen die ID jedoch leer.
        // Bisher bekam der Tool-Resultat-Turn dann eine zufällige andere ID und wurde vom
        // Endpoint mit HTTP 400 abgelehnt – das Modell konnte seinen fehlerhaften Aufruf nicht
        // mehr korrigieren. Die deterministische Ersatz-ID bleibt über UI, Folge-Turn und
        // persistierte Historie identisch.
        var toolCalls = Self.normalizedToolCalls(receivedToolCalls, messageID: assistantMsgId)
        if toolCalls.count > Self.maxToolCallsPerRound {
            for index in Self.maxToolCallsPerRound..<toolCalls.count {
                toolCalls[index].result =
                    "Nicht ausgeführt: In einer Tool-Runde sind höchstens \(Self.maxToolCallsPerRound) parallele Aufrufe erlaubt."
            }
        }
        sessions[sessionIdx].messages[mIdx].toolCalls = toolCalls

        // Ein Modell darf nach einer konkreten Fehlermeldung mit korrigiertem Code oder
        // geänderten Argumenten weiterarbeiten. Den exakt gleichen fehlerhaften Aufruf führen
        // wir innerhalb dieses Turns aber nicht erneut aus: Gerade bei Python-/HTML-Fehlern
        // erzeugte das sonst eine sichtbare Wiederholungsschleife ohne neuen Informationsgewinn.
        let blockedCalls = toolCalls.filter {
            blockedToolInvocationSignatures.contains(Self.toolInvocationSignature($0))
        }
        if !blockedCalls.isEmpty {
            var guardedCalls = toolCalls
            for index in guardedCalls.indices {
                let signature = Self.toolInvocationSignature(guardedCalls[index])
                guard blockedToolInvocationSignatures.contains(signature) else { continue }
                guardedCalls[index].result =
                    "Dieser identische Tool-Aufruf wurde nach einem vorherigen Fehler in diesem Turn nicht erneut ausgeführt. Ändere die Argumente oder den Code, oder fahre ohne diesen Aufruf fort."
            }
            sessions[sessionIdx].messages[mIdx].toolCalls = guardedCalls
            if blockedCalls.count == toolCalls.count {
                if sessions[sessionIdx].messages[mIdx].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sessions[sessionIdx].messages[mIdx].content =
                        "Der identische fehlerhafte Tool-Aufruf wurde nicht wiederholt. Bitte korrigiere die Argumente oder fahre ohne dieses Tool fort."
                }
                finishExchange(sessionId: sessionId)
                return
            }
        }

        toolCallDepth += 1
        let capturedCalls = sessions[sessionIdx].messages[mIdx].toolCalls ?? toolCalls
        let capturedSessionID = sessions[sessionIdx].id.uuidString
        // Generation für den asynchronen Tool-Lauf einfrieren (Audit H3): Nach einem
        // cancelStreaming() während der Tool-Ausführung ist die Generation rotiert – der
        // cancelte Task darf isStreaming und den Folge-Stream nicht mehr anfassen.
        let generation = streamGeneration

        // Der Tool-Task wird referenziert, damit cancelStreaming() ihn stoppen kann. Vorher
        // lief die Tool-Runde nach dem Nutzer-Abbruch weiter und startete danach heimlich
        // einen Folge-Stream, obwohl die UI bereits "idle" zeigte.
        toolContinuationTask = Task { [weak self] in
            // Tools über Registry parallel ausführen
            var updated = capturedCalls
            var failedSignatures: Set<String> = []
            var artifactsByIndex: [Int: [ToolArtifact]] = [:]
            await withTaskGroup(of: (Int, ToolResult).self) { group in
                for (i, tc) in updated.enumerated() where tc.result == nil {
                    group.addTask {
                        let result = await ToolRegistry.shared.execute(name: tc.name, arguments: tc.arguments, sessionID: capturedSessionID)
                        return (i, result)
                    }
                }
                for await (i, result) in group {
                    updated[i].result = result.formatted
                    updated[i].source = result.source
                    if result.isError {
                        failedSignatures.insert(Self.toolInvocationSignature(updated[i]))
                    }
                    if !result.artifacts.isEmpty { artifactsByIndex[i] = result.artifacts }
                }
            }

            // Audit H3: Nach cancelStreaming() ist isStreaming bereits false und die Queue-
            // Unterdrückung aktiv. Der frühere `isStreaming = false`-Reset hier traf dann den
            // evtl. bereits neu gestarteten Stream einer Folgenachricht und löste über den
            // didSet eine Kettenreaktion weiterer automatischer Sends aus. Cancelte Tasks
            // verlassen die Runde hier still – cancelStreaming() hat den Zustand schon gepflegt.
            if Task.isCancelled { return }
            guard let self else { return }
            let generationStillCurrent = await MainActor.run { self.streamGeneration == generation }
            guard generationStillCurrent else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.toolContinuationTask = nil
                guard let sessionIdx = self.sessions.firstIndex(where: { $0.id == sessionId }) else {
                    self.failCurrentExchange(sessionId: sessionId, targetMsgId: assistantMsgId,
                                              message: "Die Session wurde während der Tool-Ausführung gelöscht.")
                    return
                }
                // Message-Index nach dem asynchronen Tool-Lauf NEU suchen – der vorher
                // eingefrorene Index konnte veralten, wenn die Nachricht inzwischen entfernt
                // oder verschoben wurde.
                guard let mIdx = self.sessions[sessionIdx].messages.firstIndex(where: { $0.id == assistantMsgId }) else {
                    self.failCurrentExchange(sessionId: sessionId, targetMsgId: assistantMsgId,
                                              message: "Die Nachricht wurde während der Tool-Ausführung gelöscht.")
                    return
                }

                self.sessions[sessionIdx].messages[mIdx].toolCalls = updated
                self.blockedToolInvocationSignatures.formUnion(failedSignatures)

                guard let url = EndpointManager.chatCompletionsURL(for: profile) else {
                    self.failCurrentExchange(sessionId: sessionId, targetMsgId: assistantMsgId,
                                              message: "Ungültige Endpunkt-URL im Profil „\(profile.name)“.")
                    return
                }
                var nextMessages = prevMessages

                let currentContent = self.sessions[sessionIdx].messages[mIdx].content
                let tcs: [[String: Any]] = updated.map { tc in
                    ["id": tc.id, "type": "function",
                     "function": ["name": tc.name, "arguments": tc.arguments] as [String: Any]]
                }
                nextMessages.append(["role": "assistant",
                                      "content": currentContent.isEmpty ? NSNull() : currentContent,
                                      "tool_calls": tcs])

                for tc in updated {
                    let toolContent = (tc.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let finalResult = toolContent.isEmpty ? "Fehler: Das Tool hat kein Ergebnis geliefert." : toolContent
                    nextMessages.append([
                        "role": "tool",
                        "tool_call_id": tc.id,
                        "content": finalResult
                    ])
                }

                // Artefakte (Bilder, interaktives HTML) direkt als eigene Chat-Nachrichten einfügen –
                // unabhängig davon, ob das Modell sie in seiner nächsten Antwort erwähnt.
                for (_, artifacts) in artifactsByIndex.sorted(by: { $0.key < $1.key }) {
                    for artifact in artifacts {
                        switch artifact {
                        case .image(let base64):
                            self.sessions[sessionIdx].messages.append(
                                ChatMessage(role: "assistant", content: "",
                                            imageBase64: base64, imageID: UUID()))
                        case .html(let html):
                            self.sessions[sessionIdx].messages.append(
                                ChatMessage(role: "assistant", content: "", htmlArtifact: html))
                        }
                    }
                }

                let newMsgId = UUID()
                self.sessions[sessionIdx].messages.append(
                    ChatMessage(id: newMsgId, role: "assistant", content: ""))

                // Defensive: Der Folge-Stream startet im "streaming"-Zustand. isStreaming ging
                // hier zwar nie auf false (das tun nur sendMessage-Reset, cancelStreaming,
                // finishExchange und Fehlerpfade) – das explizite Setzen verhindert aber die
                // historische Inkonsistenz, dass Tokens eintrafen, während die UI "idle" zeigte.
                self.isStreaming = true
                self.startStream(profile: profile, url: url, messages: nextMessages,
                                 targetMsgId: newMsgId, sessionId: sessionId,
                                 isFallbackAttempt: self.isUsingFallback,
                                 generation: generation)
            }
        }
    }

    // MARK: - Hintergrund-Jobs (Phase 7C)
    // Laufen erst NACH einer vollständig abgeschlossenen Antwort-Runde (kein Streaming mehr aktiv),
    // damit sie nicht um Netzwerk-/Modell-Kapazität mit der eigentlichen Konversation konkurrieren.
    // Status wird über `backgroundJobStatus` in der MetricsBar sichtbar gemacht.

    /// Beendet die aktuelle Antwort-Runde mit einer sichtbaren Fehlermeldung an der Ziel-Bubble,
    /// ohne die nächste Queue-Nachricht automatisch nachzufeuern (Audit M1/M4): Nach fehlge-
    /// schlagenem Runden-Start (ungültige URL, Payload-Fehler, gelöschte Session/Nachricht) darf
    /// keine Folgenachricht blind gegen denselben kaputten Endpunkt gesendet werden.
    private func failCurrentExchange(sessionId: UUID, targetMsgId: UUID, message: String) {
        if let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
           let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == targetMsgId }) {
            sessions[sIdx].messages[mIdx].errorMessage = message
        }
        suppressQueueAutoAdvance = true
        isStreaming = false
        suppressQueueAutoAdvance = false
    }

    /// Beendet eine Antwort-Runde und stößt ggf. Hintergrund-Jobs an. Einziger Ort, an dem
    /// `isStreaming` nach erfolgreichem Abschluss (nicht Fehler/Abbruch) zurückgesetzt wird.
    private func finishExchange(sessionId: UUID) {
        isStreaming = false
        runBackgroundJobsIfNeeded(sessionId: sessionId)
        refreshCompactionHint() // Auto-Kompakt-Angebot prüfen (Phase H)
    }

    private func runBackgroundJobsIfNeeded(sessionId: UUID) {
        guard let sessionIdx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        let session = sessions[sessionIdx]

        if autoLabelingEnabled {
            // WICHTIG: `sendMessage()` setzt bereits synchron einen (groben) Titel aus den ersten
            // 40 Zeichen der User-Nachricht, BEVOR diese Methode je läuft – ein "sieht noch
            // unbetitelt aus"-Check (== "Neuer Chat") würde daher nach der allerersten Nachricht
            // NIE MEHR zutreffen und das Auto-Labeling faktisch permanent deaktivieren (beobachteter
            // Bug: "Hintergrundlabeling funktioniert nicht"). Stattdessen: auslösen, solange der
            // Titel noch der rohe Nachricht-Präfix (oder "Neuer Chat") ist – das deckt auch den
            // Fall ab, dass die erste Runde mehrere Assistant-Textnachrichten enthielt (Tool-Runde
            // mit Zwischentext), bei dem ein exakter `count == 1`-Trigger nie mehr griff.
            let stillDefaultTitle: Bool
            if session.title == "Neuer Chat" {
                stillDefaultTitle = true
            } else if let firstUser = session.messages.first(where: { $0.role == "user" }) {
                stillDefaultTitle = session.title == String(firstUser.content.prefix(40))
            } else {
                stillDefaultTitle = false
            }
            if stillDefaultTitle, !titlingInProgress.contains(sessionId) {
                let titleBeforeGeneration = session.title
                Task {
                    // Siehe waitUntilIdle(): eine gequeute Folgenachricht kann isStreaming
                    // zwischen dem Aufruf hier und der eigentlichen Ausführung bereits wieder auf
                    // true gesetzt haben (siehe isStreaming-didSet) – dann NICHT parallel zur neu
                    // gestarteten Konversation um Modell-/Netzwerkkapazität konkurrieren.
                    await self.waitUntilIdle()
                    await self.generateTitle(sessionId: sessionId, previousTitle: titleBeforeGeneration)
                }
            }
        }

        if autoImageToTextEnabled,
           let msg = session.messages.last(where: { $0.role == "user" && $0.imageBase64 != nil && $0.imageDescription == nil }),
           !describingImages.contains(msg.id) {
            let base64 = msg.imageBase64!
            let msgId = msg.id
            Task {
                await self.waitUntilIdle()
                await self.describeImage(sessionId: sessionId, messageId: msgId, base64: base64)
            }
        }
    }

    /// Wartet, bis `isStreaming` wieder `false` ist. Schützt die beiden Hintergrund-Jobs oben davor,
    /// mit einer Konversation um Modell-/Netzwerkkapazität zu konkurrieren, die durch eine gequeute
    /// Folgenachricht (siehe `isStreaming`-didSet) unmittelbar nach Abschluss der vorigen Antwort
    /// bereits wieder neu gestartet wurde, bevor `runBackgroundJobsIfNeeded` überhaupt lief. Ohne
    /// dieses Warten lief z.B. bei LM Studio der Titel-Job UND die nachgereichte Nachricht
    /// gleichzeitig gegen dasselbe Modell – die nachgereichte Antwort kam dabei nicht sauber an.
    /// Zeitlich begrenzt (10 min) und abbruchfähig, damit ein jemals hängendes `isStreaming`
    /// (historischer Bug beim Coding-Tool-Timeout) nicht dauerhaft alle Titel-/Bild-Jobs blockiert.
    private func waitUntilIdle() async {
        let idleTimeout = Date().addingTimeInterval(600)
        while isStreaming && Date() < idleTimeout && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Auto-Labeling: generiert nach der ersten vollständigen Antwort einen kurzen, passenden
    /// Titel für den Chat (löst die pauschale "erste 40 Zeichen"-Titelvergabe ab).
    private func generateTitle(sessionId: UUID, previousTitle: String) async {
        titlingInProgress.insert(sessionId)
        defer { titlingInProgress.remove(sessionId) }

        guard let sessionIdx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        let context = Array(sessions[sessionIdx].messages.filter { $0.role == "user" || $0.role == "assistant" }.prefix(6))
        guard !context.isEmpty else { return }

        backgroundJobStatus = "Generiere Titel..."
        defer { if backgroundJobStatus == "Generiere Titel..." { backgroundJobStatus = nil } }

        let title = await sendInvisiblePrompt(
            "Fasse das bisherige Gespräch in einem sehr kurzen, prägnanten Titel zusammen " +
            "(max. 6 Wörter, keine Anführungszeichen, keine Emojis, kein Punkt am Ende). Antworte NUR mit dem Titel.",
            context: context,
            useBackgroundJobModel: true
        )
        // Fehler (Netzwerk/HTTP) werden nicht als Titel übernommen – früher landete z.B.
        // "Netzwerkfehler: ..." als Chat-Titel in der Sidebar.
        guard let title, !title.isEmpty else { return }

        let cleaned = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'„“”.·"))
        guard !cleaned.isEmpty, cleaned.count < 200 else { return }

        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        // Nur überschreiben, wenn sich der Titel zwischenzeitlich nicht schon geändert hat
        // (z.B. weil der Nutzer manuell umbenannt hat, während der Job lief) – exakter Vergleich
        // mit dem beim Auslösen erfassten Titel statt einer "sieht unbetitelt aus"-Heuristik,
        // die nach der ersten Nachricht nie mehr zutrifft (s. Kommentar in runBackgroundJobsIfNeeded).
        guard sessions[idx].title == previousTitle else { return }
        sessions[idx].title = String(cleaned.prefix(50))
    }

    /// Bild-zu-Text: beschreibt einen angehängten Screenshot im Hintergrund, damit ältere
    /// Bilder im Verlauf als günstiger Text statt als erneut mitgeschicktes Rohbild zur
    /// Verfügung stehen (siehe `apiMessages`).
    private func describeImage(sessionId: UUID, messageId: UUID, base64: String) async {
        // Doppel-Ausführungsschutz (Audit M11): sendMessage und runBackgroundJobsIfNeeded
        // stößen beide Task-Instanzen an (je hinter waitUntilIdle) – ohne Guard würde dasselbe
        // Bild vom ersten Task beschrieben und vom zweiten nochmal (zweiter Modell-Roundtrip).
        guard !describingImages.contains(messageId) else { return }
        if let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
           let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == messageId }),
           sessions[sIdx].messages[mIdx].imageDescription != nil {
            return // bereits beschrieben
        }
        describingImages.insert(messageId)
        defer { describingImages.remove(messageId) }

        backgroundJobStatus = "Beschreibe Bild..."
        defer { if backgroundJobStatus == "Beschreibe Bild..." { backgroundJobStatus = nil } }

        let description = await sendInvisiblePrompt(
            "Beschreibe kurz und präzise (2-4 Sätze), was auf diesem Screenshot zu sehen ist. " +
            "Antworte NUR mit der Beschreibung, ohne Einleitung.",
            context: [],
            imageBase64: base64,
            useBackgroundJobModel: true
        )
        // Bei Fehlern bleibt imageDescription nil – der Freeze-Mechanismus snapshotet dann
        // nil und die Nachricht wird ohne Bildkontext eingefroren (weiterhin korrekt).
        guard let description else { return }

        guard let sessionIdx = sessions.firstIndex(where: { $0.id == sessionId }),
              let msgIdx = sessions[sessionIdx].messages.firstIndex(where: { $0.id == messageId })
        else { return }
        sessions[sessionIdx].messages[msgIdx].imageDescription = description
    }

    // MARK: - Tool-Registry-Sync

    /// Injiziert konfigurierbare Werte (searxngURL, maxBrowseCharacters) in die Registry-Tools.
    /// Muss nach loadSettings() und nach Settings-Änderungen aufgerufen werden.
    func syncToolRegistry() {
        let registry = ToolRegistry.shared
        if let searchTool = registry.tool(named: "web_search") as? WebSearchTool {
            searchTool.searxngURL = searxngURL
            searchTool.isEnabled = searchEnabled
        }
        if let browseTool = registry.tool(named: "browse_url") as? BrowseURLTool {
            browseTool.maxBrowseCharacters = maxBrowseCharacters
        }
        // Persistenz-Audit: Tool-Zustände leben in der Registry, nicht als @Published – der
        // globale Einstellungs-Autosave bekommt ihre Änderungen nicht mit. syncToolRegistry()
        // läuft ausschließlich bei nutzergesteuerten Tool-Änderungen (und einmal im Init mit
        // identischem Zustand) – hier ist ein direkter Save der richtige Ort, damit Tool-
        // Toggles auch bei ESC-Close des Settings-Sheets + Crash erhalten bleiben.
        saveSettings()
    }

    /// Aktiviert/deaktiviert Web-Suche UND URL-Browsing gemeinsam – passend zum Label "Suche &
    /// Browsing aktivieren" in SearchTabView. Vorher setzte dieser eine Schalter NUR `searchEnabled`
    /// (→ nur web_search.isEnabled via syncToolRegistry), browse_url.isEnabled wurde davon NIE
    /// berührt und blieb unabhängig vom Toggle-Zustand auf seinem Default (aus) – Browsing
    /// funktionierte dadurch nie, obwohl der Schalter das Gegenteil versprach. Ruft zusätzlich
    /// sofort saveSettings()/syncToolRegistry() auf: die reinen @Published-Properties allein wirkten
    /// sich vorher erst nach einem Neustart (oder einem zufälligen Toggle im Tools-Tab) tatsächlich
    /// auf die ToolRegistry aus, da nur syncToolRegistry() die Werte in die Live-Tool-Instanzen
    /// überträgt.
    func setSearchAndBrowsingEnabled(_ enabled: Bool) {
        searchEnabled = enabled
        if let browseTool = ToolRegistry.shared.tool(named: "browse_url") {
            browseTool.isEnabled = enabled
        }
        syncToolRegistry()
        saveSettings()
    }

    // MARK: - Hilfsmethoden

    /// Friert für alle Nachrichten außer `excludedId` (der neuen, gerade hervorgehobenen
    /// Nachricht) den Bildkontext einmalig ein – siehe `ChatMessage.frozenImageContext`.
    /// Läuft synchron auf dem Main-Actor, direkt bevor eine neue Anfrage aufgebaut wird.
    private func freezeImageContextForOlderMessages(sessionIdx: Int, excluding excludedId: UUID) {
        guard !keepMultipleImagesInHistory else { return } // dort werden Bilder ohnehin immer roh mitgeschickt
        for i in sessions[sessionIdx].messages.indices {
            let msg = sessions[sessionIdx].messages[i]
            guard msg.role == "user", msg.id != excludedId, msg.imageBase64 != nil,
                  !msg.isImageContextFrozen else { continue }
            sessions[sessionIdx].messages[i].frozenImageContext = msg.imageDescription
            sessions[sessionIdx].messages[i].isImageContextFrozen = true
        }
    }

    /// Inline-Think-Tag-Paar, per Unicode-Escapes geschrieben (identisch zu den Tags im
    /// StreamingDelegate, bewusst ohne Literal im Quelltext).
    private static let thinkOpenTag = "\u{3C}think\u{3E}"
    private static let thinkCloseTag = "\u{3C}/think\u{3E}"

    /// Content-Ersatz für Assistant-Nachrichten ohne sichtbaren Text: der Denkprozess
    /// wird als Inline-Think-Block gesendet. (Fix: Vorher standen hier versehentlich
    /// verdoppelte Backslashes - das Modell erhielt den Literal-Text statt des Denkprozesses.)
    private static func thinkingOnlyContent(_ thinking: String) -> String {
        thinkOpenTag + "\n" + thinking + "\n" + thinkCloseTag
    }

    // MARK: - Kontext-Budget

    /// Grobe Token-Schätzung für einen API-Payload-Eintrag (Zeichen/4 + Fixkosten pro
    /// Nachricht). Bilder werden als konservativer Pauschalwert angesetzt, da die echten
    /// visuellen Token server- und auflösungsabhängig sind. Für das Budget-Trimmen reicht
    /// eine grobe, aber deterministische Schätzung vollständig aus.
    static func estimatedTokens(of message: [String: Any]) -> Int {
        let content: Any = message["content"] ?? NSNull()
        var chars = 0
        var images = 0
        if let s = content as? String {
            chars = s.count
        } else if let parts = content as? [[String: Any]] {
            for part in parts {
                if let t = part["text"] as? String { chars += t.count }
                if part["image_url"] != nil { images += 1 }
            }
        }
        if let imagesField = message["images"] as? [String] { images += imagesField.count }
        // Ollama liefert Bilder als flaches base64-Array statt als content-Teile.
        return chars / 4 + images * 2500 + 16
    }

    /// Kürzt den Payload deterministisch auf das geschätzte Kontextbudget, damit lange Chats
    /// (inkl. Volltext-Dokumenten-Anhängen) nicht irgendwann mit HTTP 400 vom Server abgewiesen
    /// werden. Entfernt die ältesten Runden als ganze Segmente (User-/Assistant-Nachricht inkl.
    /// ihrer tool-Resultate, damit kein Tool-Call ohne Ergebnis verwaist und der Server die
    /// Folge-Anfrage mit 400 ablehnt). System-Nachricht (Index 0) und die letzte Runde bleiben
    /// immer erhalten. Deterministisch, damit der Prompt-Präfix bei unverändertem Verlauf
    /// stabil bleibt und der serverseitige KV-Cache nicht unnötig invalidiert wird.
    static func trimmedToContextBudget(_ messages: [[String: Any]], contextWindow: Int?, maxTokens: Int?) -> [[String: Any]] {
        // 75 % des Fensters als Prompt-Budget, der Rest als Reserve für die Antwort.
        let window = max(contextWindow ?? 8192, 2048)
        let reserve = min(maxTokens ?? 1024, window / 4)
        let budget = max(window - reserve, window / 2)

        func total(_ msgs: [[String: Any]]) -> Int {
            msgs.reduce(0) { $0 + estimatedTokens(of: $1) }
        }
        guard total(messages) > budget, messages.count > 2 else { return messages }

        // Segmente ab Index 1 bilden: Ein Segment beginnt mit einer Nicht-tool-Nachricht und
        // schließt direkt folgende tool-Ergebnisse mit ein.
        var segments: [Range<Int>] = []
        var start = 1
        var i = 1
        while i < messages.count {
            if let role = messages[i]["role"] as? String, role == "tool" {
                i += 1
                continue
            }
            if i > start { segments.append(start..<i) }
            start = i
            i += 1
        }
        segments.append(start..<messages.count)

        var remaining = total(messages)
        var removeUntil = 0
        // Das letzte Segment (enthält die aktuelle User-Nachricht) bleibt immer erhalten.
        for segment in segments.dropLast() {
            if remaining <= budget { break }
            for idx in segment {
                remaining -= estimatedTokens(of: messages[idx])
            }
            removeUntil = segment.upperBound
        }
        guard removeUntil > 0 else { return messages }

        var trimmed = Array(messages[removeUntil...])
        if let system = trimmed.first, (system["role"] as? String) == "system" {
            trimmed.insert(["role": "system",
                            "content": "[System: Ältere Nachrichten wurden zur Einhaltung des Kontextfensters ausgelassen.]"],
                           at: 1)
        }
        return trimmed
    }

    // MARK: - Streaming-Kompletion für eigenständige Mini-UIs (Inline-Erklärung)

    /// Latch, mit dem der Aufrufer von streamCompletion() auf das Ende des Streams warten kann.
    final class StreamLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var resumed = false

        func wait() async {
            await withCheckedContinuation { c in
                lock.lock(); defer { lock.unlock() }
                if resumed { c.resume() } else { continuation = c }
            }
        }

        func finish() {
            lock.lock(); defer { lock.unlock() }
            resumed = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// Startet einen eigenständigen Streaming-Request (mit eigenem StreamingDelegate) und gibt
    /// einen Task zurück, der endet, sobald der Stream fertig, fehlgeschlagen oder abgebrochen
    /// ist. Die Basis für die Inline-Erklärung – ersetzt dort den früheren 60-Sekunden-Sleep-
    /// Hack: onFinish/onError lösen das Warten garantiert aus, ein Task-Cancel bricht die
    /// zugrunde liegende dataTask ab. Chunk-Callbacks kommen auf der Delegate-Queue; für
    /// geordnete UI-Updates muss der Aufrufer auf den Main-Thread dispatchen.
    func streamCompletion(profile: EndpointProfile?, messages: [[String: Any]],
                          onChunk: @escaping (String) -> Void,
                          onError: @escaping (String) -> Void) -> Task<Void, Never> {
        Task {
            guard let profile = profile ?? activeProfile,
                  let url = EndpointManager.chatCompletionsURL(for: profile) else {
                onError("Kein Endpunkt konfiguriert.")
                return
            }

            var payload: [String: Any] = [
                "model": profile.model,
                "messages": messages,
                "stream": true,
                "stream_options": ["include_usage": true]
            ]
            payload = EndpointManager.adaptPayload(payload, for: profile)
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
                onError("Interner Fehler beim Aufbau der Anfrage.")
                return
            }

            var request = URLRequest(url: url, timeoutInterval: 120)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            EndpointManager.authHeaders(for: profile).forEach { request.setValue($1, forHTTPHeaderField: $0) }
            request.httpBody = data

            let latch = StreamLatch()
            let delegate = StreamingDelegate(
                onChunk: { chunk, type in
                    guard case .content = type else { return }
                    onChunk(chunk)
                },
                onFinish: { latch.finish() },
                onError: { error in
                    // Nutzer-Abbruch ist kein anzeigbarer Fehler.
                    guard (error as? URLError)?.code != .cancelled else {
                        latch.finish()
                        return
                    }
                    onError(error.localizedDescription)
                    latch.finish()
                },
                isNDJSON: profile.provider == .ollama
            )

            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let dataTask = session.dataTask(with: request)
            dataTask.resume()

            await withTaskCancellationHandler {
                await latch.wait()
            } onCancel: {
                dataTask.cancel()
            }
            session.finishTasksAndInvalidate()
        }
    }

    /// Wandelt eine ChatMessage in ein oder mehrere API-Payload-Dicts um.
    private func apiMessages(for msg: ChatMessage,
                              highlightedUserMsgId: UUID,
                              provider: EndpointProvider) -> [[String: Any]] {
        switch msg.role {
        case "user":
            let attachImage = msg.id == highlightedUserMsgId || keepMultipleImagesInHistory
            if attachImage, let b64 = msg.imageBase64 {
                let text = msg.content.isEmpty ? "Beschreibe diesen Screenshot." : msg.content
                return [EndpointManager.userImageMessage(text: text, base64: b64, provider: provider)]
            }
            // Bild-zu-Text: NUR den eingefrorenen Snapshot lesen, NIE das live `imageDescription`
            // direkt – sonst würde sich der Prompt-Präfix dieser Nachricht zwischen Anfragen
            // ändern (mal ohne, mal mit Beschreibung, je nach Timing des Hintergrund-Jobs) und den
            // KV-Cache des Servers ab dieser Stelle für die gesamte restliche Konversation
            // invalidieren. Siehe ChatMessage.frozenImageContext.
            if !attachImage, msg.isImageContextFrozen, let description = msg.frozenImageContext, !description.isEmpty {
                let combined = msg.content.isEmpty
                    ? "[Screenshot]: \(description)"
                    : "\(msg.content)\n\n[Screenshot-Beschreibung]: \(description)"
                return [["role": "user", "content": combined]]
            }
            return [["role": "user", "content": msg.content]]

        case "assistant":
            if let tcs = msg.toolCalls, !tcs.isEmpty {
                // Auch ältere, bereits gespeicherte Chats können Tool-Calls ohne ID enthalten.
                // Beim erneuten Senden muss dieselbe Ersatz-ID auf beiden Seiten stehen.
                let normalizedCalls = Self.normalizedToolCalls(tcs, messageID: msg.id)
                let tcArr: [[String: Any]] = normalizedCalls.map { tc in
                    ["id": tc.id, "type": "function",
                     "function": ["name": tc.name, "arguments": tc.arguments] as [String: Any]]
                }
                let text: String
                if !msg.content.isEmpty {
                    text = msg.content
                } else if let thinking = msg.thinking, !thinking.isEmpty {
                    text = Self.thinkingOnlyContent(thinking)
                } else {
                    text = "" // Mit tool_calls ist ein leerer String bei OpenAI erlaubt
                }
                
                var result: [[String: Any]] = [
                    ["role": "assistant",
                     "content": text,
                     "tool_calls": tcArr]
                ]
                for tc in normalizedCalls {
                    let toolResult = (tc.result ?? "").isEmpty ? "Fehler: Kein Ergebnis." : tc.result!
                    result.append(["role": "tool",
                                   "tool_call_id": tc.id,
                                   "content": toolResult])
                }
                return result
            }
            
            let text: String
            if !msg.content.isEmpty {
                text = msg.content
            } else if let thinking = msg.thinking, !thinking.isEmpty {
                text = Self.thinkingOnlyContent(thinking)
            } else {
                text = " " // Fallback um HTTP 400 Bad Request bei leerem Content zu vermeiden
            }
            return [["role": "assistant", "content": text]]

        default:
            return [["role": msg.role, "content": msg.content]]
        }
    }

    /// Stabile IDs für Tool-Calls, deren Endpoint keine ID geliefert hat. Der UUID-Anteil der
    /// Assistant-Nachricht macht die IDs chatübergreifend eindeutig, der Offset trennt mehrere
    /// Calls desselben Turns. Bereits vorhandene IDs bleiben unverändert.
    static func normalizedToolCalls(_ calls: [ToolCallInfo], messageID: UUID) -> [ToolCallInfo] {
        calls.enumerated().map { offset, call in
            guard call.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return call }
            var normalized = call
            normalized.id = "call_\(messageID.uuidString.lowercased())_\(offset)"
            return normalized
        }
    }
}
