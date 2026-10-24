import Foundation

// MARK: - Datenmodelle

enum AttachmentStatus: String, Codable, Equatable {
    case queued
    case processing
    case completed
    case failed
}

struct DocumentAttachment: Identifiable, Codable, Equatable {
    var id = UUID()
    let url: URL
    var status: AttachmentStatus = .queued
    var progressText: String = ""
    var progress: Double = 0.0
    var extractedText: String = ""
    var extractedImagePaths: [String] = [] // Optional images extracted from the document
    /// Base64 des Bildes, das GERADE im Hintergrund per Vision-Modell beschrieben wird (PDF-Seite
    /// oder eingebettetes Word/PowerPoint-Bild). Optional, da nur während `.processing` gesetzt –
    /// wird bei Abschluss/Fehler automatisch geleert (siehe ChatViewModel.updateDocument).
    var currentPreviewImageBase64: String? = nil
}

/// Interaktive Abfragekarte (Tool `quiz_card`, v. a. im Tutor-Modus).
nonisolated struct QuizCard: Codable, Equatable, Sendable {
    var question: String
    /// Antwortoptionen; leer = Freitext-Antwort.
    var options: [String]
    /// Index der richtigen Option (optional – ohne Angabe bewertet das Modell die Antwort).
    var correctIndex: Int?
    /// Wird erst nach der Antwort gezeigt.
    var explanation: String?
    var hint: String?
    /// Gewählte Option bzw. Freitext, sobald beantwortet.
    var selectedIndex: Int?
    var freeTextAnswer: String?

    var isAnswered: Bool { selectedIndex != nil || freeTextAnswer != nil }
}

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: String
    var content: String
    var thinking: String?
    var toolCalls: [ToolCallInfo]?
    var imageBase64: String?
    var imageID: UUID? // Für UI-Performance (Dereferenzierung)
    var documentAttachment: DocumentAttachment?
    var timestamp: Date?
    /// Rohes HTML eines Tool-Artefakts (z.B. `coding_sandbox` mit language=html), direkt sandboxed
    /// im Chat gerendert. Bewusst getrennt von `content`/Markdown, da markdown-it `html:false`
    /// gesetzt hat und rohes HTML dort sonst nur als escapter Text erscheinen würde.
    var htmlArtifact: String?
    /// Fehler einer gescheiterten Antwort (Fehler-UX): Bewusst ein EIGENES Feld statt Text im
    /// content – der (Teil-)Inhalt bleibt unangetastet, die UI zeigt den Fehler als Karte mit
    /// Retry-/Bearbeiten-Aktionen, und der Payload überspringt fehlgeschlagene Antworten.
    var errorMessage: String? = nil
    /// Hintergrund-generierte Textbeschreibung eines angehängten Bildes (Auto-Bild-zu-Text,
    /// siehe AdvancedTabView). NIE direkt für den API-Payload lesen (siehe `frozenImageContext`
    /// unten) – dieses Feld kann sich asynchron ändern, während die Nachricht schon Teil
    /// vergangener Anfragen war.
    var imageDescription: String?
    /// EINMALIGE, unveränderliche Momentaufnahme dessen, was für diese Nachricht ans Modell
    /// geschickt wird, sobald sie nicht mehr die aktuellste (per Bild "highlighted") Nachricht ist
    /// (siehe `ChatViewModel.applyImageRetention`). nil = kein Bildkontext.
    ///
    /// Warum das nötig ist: Ohne Einfrieren würde `apiMessages()` bei jeder Anfrage live prüfen,
    /// ob `imageDescription` inzwischen fertig ist – eine ältere Nachricht würde also mal OHNE,
    /// mal MIT Beschreibung gesendet, je nachdem wie weit der Hintergrund-Job zufällig war. Jede
    /// solche Änderung am Prompt-Präfix invalidiert den kompletten KV-Cache ab dieser Stelle für
    /// den Server (LM Studio/llama.cpp) – die gesamte restliche Konversation müsste dann bei
    /// jeder Anfrage erneut von vorne prozessiert werden, statt den Cache wiederzuverwenden.
    /// Einmal eingefroren, ist der Wert für immer fix, unabhängig davon was `imageDescription`
    /// danach noch wird.
    var frozenImageContext: String?
    var isImageContextFrozen: Bool = false
    /// Interaktive Abfragekarte (nur Anzeige; der zugehörige Tool-Call steht in der Nachricht davor).
    var quizCard: QuizCard?
    /// Kurze Originaleingabe (z. B. „/search Thrombin“), die statt des ausformulierten Prompts in der
    /// Nutzerblase und im Chat-Titel erscheint. `content` bleibt, was das Modell bekommt.
    var displayText: String?
    /// Interaktive Ausgabe: freigegebene Domains externer Bibliotheken (siehe HTMLLibraryPermissions).
    var htmlAllowedHosts: [String]?
    /// Interaktive Ausgabe eingeklappt (Klick auf die Kopfzeile).
    var artifactCollapsed: Bool?
    /// Reparierte Diagramme nur für die Anzeige (Quelltext → korrigierter Quelltext). Der Inhalt
    /// selbst bleibt unverändert, damit Verlauf und Cache des Servers gleich bleiben.
    var displayFixes: [String: String]?

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        // imageBase64 (bis zu 7MB) wird bewusst ausgeschlossen – imageID genügt als Proxy.
        // toolCalls wird vollständig verglichen, damit Tool-Ergebnisse (.result) einen
        // Re-Render auslösen (Fix: Spinner blieb sonst ewig stehen).
        lhs.id == rhs.id &&
        lhs.role == rhs.role &&
        lhs.content == rhs.content &&
        lhs.thinking == rhs.thinking &&
        lhs.toolCalls == rhs.toolCalls &&
        lhs.imageID == rhs.imageID &&
        lhs.documentAttachment == rhs.documentAttachment &&
        lhs.timestamp == rhs.timestamp &&
        lhs.htmlArtifact == rhs.htmlArtifact &&
        lhs.imageDescription == rhs.imageDescription &&
        lhs.frozenImageContext == rhs.frozenImageContext &&
        lhs.isImageContextFrozen == rhs.isImageContextFrozen &&
        lhs.errorMessage == rhs.errorMessage &&
        lhs.quizCard == rhs.quizCard &&
        lhs.displayText == rhs.displayText &&
        lhs.htmlAllowedHosts == rhs.htmlAllowedHosts &&
        lhs.artifactCollapsed == rhs.artifactCollapsed &&
        lhs.displayFixes == rhs.displayFixes
        // frozenImageContext aufnehmen (Audit 2.7): Ohne den Vergleich übersprang SwiftUIs
        // Diffing die Neuberechnung, wenn sich NUR der eingefrorene Bildkontext änderte.
    }

    init(
        id: UUID = UUID(),
        role: String,
        content: String,
        thinking: String? = nil,
        toolCalls: [ToolCallInfo]? = nil,
        imageBase64: String? = nil,
        imageID: UUID? = nil,
        documentAttachment: DocumentAttachment? = nil,
        timestamp: Date? = Date(),
        htmlArtifact: String? = nil,
        imageDescription: String? = nil,
        frozenImageContext: String? = nil,
        isImageContextFrozen: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.thinking = thinking
        self.toolCalls = toolCalls
        self.imageBase64 = imageBase64
        self.imageID = imageID
        self.documentAttachment = documentAttachment
        self.timestamp = timestamp
        self.htmlArtifact = htmlArtifact
        self.imageDescription = imageDescription
        self.frozenImageContext = frozenImageContext
        self.isImageContextFrozen = isImageContextFrozen
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, content, thinking, toolCalls, imageBase64, imageID,
             documentAttachment, timestamp, htmlArtifact, imageDescription,
             frozenImageContext, isImageContextFrozen, quizCard, displayText,
             htmlAllowedHosts, artifactCollapsed, displayFixes
    }

    /// Custom Decoder nötig, da `isImageContextFrozen` als NICHT-optionales `Bool = false`
    /// deklariert ist: Swifts synthetisierter Decoder wendet Default-Werte NICHT auf fehlende
    /// JSON-Keys an (das gilt nur für echte Optionals) – er würde stattdessen einen Decoding-Error
    /// werfen. `SessionStore.loadAll` fängt diesen Error mit `try?` ab und verwirft die gesamte
    /// Session lautlos, d.h. ALLE vor Einführung dieses Felds gespeicherten Chats würden beim
    /// nächsten Start spurlos aus der Sidebar verschwinden. Deshalb hier explizit mit Fallback.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(String.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        thinking = try c.decodeIfPresent(String.self, forKey: .thinking)
        toolCalls = try c.decodeIfPresent([ToolCallInfo].self, forKey: .toolCalls)
        imageBase64 = try c.decodeIfPresent(String.self, forKey: .imageBase64)
        imageID = try c.decodeIfPresent(UUID.self, forKey: .imageID)
        documentAttachment = try c.decodeIfPresent(DocumentAttachment.self, forKey: .documentAttachment)
        timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp)
        htmlArtifact = try c.decodeIfPresent(String.self, forKey: .htmlArtifact)
        imageDescription = try c.decodeIfPresent(String.self, forKey: .imageDescription)
        frozenImageContext = try c.decodeIfPresent(String.self, forKey: .frozenImageContext)
        isImageContextFrozen = try c.decodeIfPresent(Bool.self, forKey: .isImageContextFrozen) ?? false
        quizCard = try? c.decodeIfPresent(QuizCard.self, forKey: .quizCard)
        displayText = try c.decodeIfPresent(String.self, forKey: .displayText)
        htmlAllowedHosts = try? c.decodeIfPresent([String].self, forKey: .htmlAllowedHosts)
        artifactCollapsed = try? c.decodeIfPresent(Bool.self, forKey: .artifactCollapsed)
        displayFixes = try? c.decodeIfPresent([String: String].self, forKey: .displayFixes)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(thinking, forKey: .thinking)
        try c.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try c.encodeIfPresent(imageBase64, forKey: .imageBase64)
        try c.encodeIfPresent(imageID, forKey: .imageID)
        try c.encodeIfPresent(documentAttachment, forKey: .documentAttachment)
        try c.encodeIfPresent(timestamp, forKey: .timestamp)
        try c.encodeIfPresent(htmlArtifact, forKey: .htmlArtifact)
        try c.encodeIfPresent(imageDescription, forKey: .imageDescription)
        try c.encodeIfPresent(frozenImageContext, forKey: .frozenImageContext)
        try c.encode(isImageContextFrozen, forKey: .isImageContextFrozen)
        try c.encodeIfPresent(quizCard, forKey: .quizCard)
        try c.encodeIfPresent(displayText, forKey: .displayText)
        try c.encodeIfPresent(htmlAllowedHosts, forKey: .htmlAllowedHosts)
        try c.encodeIfPresent(artifactCollapsed, forKey: .artifactCollapsed)
        try c.encodeIfPresent(displayFixes, forKey: .displayFixes)
    }
}

nonisolated struct ToolCallInfo: Identifiable, Codable, Equatable, Sendable {
    /// Manche OpenAI-kompatiblen Server (insbesondere bei Ollama) liefern keine Call-ID.
    /// Die App ergänzt dann vor der Tool-Fortsetzung eine stabile, lokale ID.
    var id: String
    let index: Int? // Tracking during streaming
    var name: String
    var arguments: String
    var result: String?
    var source: String?
    /// Tool-Rundenlimit: `.finalRound` = letzte erlaubte Runde (der API-Inhalt bekommt den
    /// Abschluss-Hinweis), `.notExecuted` = nach dem Limit nicht mehr ausgeführt.
    var limitNote: ToolLimitNote? = nil
    /// `recall_screenshot`: Nummer des erneut angehängten Screenshots. Das Bild selbst wird beim
    /// Aufbau des Requests aus dem Chat geholt – so ist der Verlauf identisch zur Tool-Runde.
    var recalledScreenshot: Int? = nil
    /// Abbildungen aus der Recherche (web_search/browse_url), im ganzen Chat eindeutig nummeriert.
    var researchImages: [ResearchImageRef]? = nil
    /// Zeiten und Zustand der Recherche-Quellen (nur Anzeige im Tool-Schritt).
    var researchStatus: [ResearchSourceStatus]? = nil
    /// Dauer der Recherche-Schritte (nur Anzeige im Tool-Schritt).
    var researchPhases: [ResearchPhaseTiming]? = nil
}

nonisolated enum ToolLimitNote: String, Codable, Sendable {
    case finalRound
    case notExecuted
}
