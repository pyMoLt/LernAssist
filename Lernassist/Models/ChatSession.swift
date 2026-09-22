import Foundation

struct Flashcard: Identifiable, Codable, Equatable {
    var id = UUID()
    let front: String
    let back: String
    /// Nächster Fälligkeitszeitpunkt (vereinfachtes SM-2-System). Frisch generierte Karten sind
    /// sofort fällig (Default = jetzt).
    var dueDate: Date = Date()
    var intervalDays: Double = 0
    var easeFactor: Double = 2.5
    var repetitionCount: Int = 0
    var lastReviewedAt: Date? = nil

    private enum CodingKeys: String, CodingKey {
        case id, front, back, dueDate, intervalDays, easeFactor, repetitionCount, lastReviewedAt
    }

    init(id: UUID = UUID(), front: String, back: String, dueDate: Date = Date(),
         intervalDays: Double = 0, easeFactor: Double = 2.5, repetitionCount: Int = 0,
         lastReviewedAt: Date? = nil) {
        self.id = id
        self.front = front
        self.back = back
        self.dueDate = dueDate
        self.intervalDays = intervalDays
        self.easeFactor = easeFactor
        self.repetitionCount = repetitionCount
        self.lastReviewedAt = lastReviewedAt
    }

    /// Custom Decoder nötig: dueDate/intervalDays/easeFactor/repetitionCount sind NICHT-optionale
    /// Felder mit Default-Wert – Swifts synthetisierter Decoder wendet Defaults NICHT auf fehlende
    /// JSON-Keys an (das gilt nur für echte Optionals), sondern wirft einen Decoding-Error. Ohne
    /// diesen Custom-Decoder wären ALLE vor Einführung von Spaced Repetition gespeicherten
    /// Karteikarten beim nächsten Laden verworfen worden (SessionStore verwirft Decode-Fehler
    /// pro Session lautlos über try?).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        front = try c.decode(String.self, forKey: .front)
        back = try c.decode(String.self, forKey: .back)
        dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate) ?? Date()
        intervalDays = try c.decodeIfPresent(Double.self, forKey: .intervalDays) ?? 0
        easeFactor = try c.decodeIfPresent(Double.self, forKey: .easeFactor) ?? 2.5
        repetitionCount = try c.decodeIfPresent(Int.self, forKey: .repetitionCount) ?? 0
        lastReviewedAt = try c.decodeIfPresent(Date.self, forKey: .lastReviewedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(front, forKey: .front)
        try c.encode(back, forKey: .back)
        try c.encode(dueDate, forKey: .dueDate)
        try c.encode(intervalDays, forKey: .intervalDays)
        try c.encode(easeFactor, forKey: .easeFactor)
        try c.encode(repetitionCount, forKey: .repetitionCount)
        try c.encodeIfPresent(lastReviewedAt, forKey: .lastReviewedAt)
    }
}

// MARK: - Spaced Repetition (vereinfachtes SM-2)

enum FlashcardRating: String, CaseIterable, Identifiable {
    case again, hard, good, easy
    var id: String { rawValue }

    var label: String {
        switch self {
        case .again: return "Nochmal"
        case .hard:  return "Schwer"
        case .good:  return "Gut"
        case .easy:  return "Einfach"
        }
    }

    var color: String {
        switch self {
        case .again: return "red"
        case .hard:  return "orange"
        case .good:  return "green"
        case .easy:  return "blue"
        }
    }
}

extension Flashcard {
    /// Obergrenze fürs Intervall (~10 Jahre) und den Ease-Faktor. Ohne diese Deckelung würde
    /// wiederholtes "Einfach"-Bewerten derselben Karte `intervalDays` unbegrenzt multiplikativ
    /// wachsen lassen – irgendwann passt der Wert nicht mehr in einen Int, und
    /// `Int(intervalDays.rounded())` würde beim Umwandeln abstürzen (Swift-Trap bei
    /// Double→Int-Konvertierung außerhalb des darstellbaren Bereichs). Reale SRS-Systeme
    /// (Anki, SM-2) deckeln aus genau diesem Grund beide Werte.
    private static let maxIntervalDays: Double = 3650
    private static let maxEaseFactor: Double = 5.0

    /// Aktualisiert Intervall/Ease-Faktor/Fälligkeitsdatum nach einer Nutzer-Bewertung. Bewusst ein
    /// vereinfachtes SM-2 (kein volles Anki-Modell) – reicht für den Zweck, ist aber leicht
    /// nachvollziehbar und wartbar.
    mutating func applyReview(_ rating: FlashcardRating, now: Date = Date()) {
        lastReviewedAt = now
        switch rating {
        case .again:
            repetitionCount = 0
            intervalDays = 0
            dueDate = Calendar.current.date(byAdding: .minute, value: 10, to: now) ?? now
        case .hard:
            easeFactor = max(1.3, easeFactor - 0.15)
            repetitionCount += 1
            intervalDays = repetitionCount <= 1 ? 1 : min(Self.maxIntervalDays, max(1, intervalDays * 1.2))
            dueDate = Calendar.current.date(byAdding: .day, value: max(1, Int(intervalDays.rounded())), to: now) ?? now
        case .good:
            repetitionCount += 1
            intervalDays = repetitionCount <= 1 ? 1 : min(Self.maxIntervalDays, intervalDays * easeFactor)
            dueDate = Calendar.current.date(byAdding: .day, value: max(1, Int(intervalDays.rounded())), to: now) ?? now
        case .easy:
            easeFactor = min(Self.maxEaseFactor, easeFactor + 0.15)
            repetitionCount += 1
            intervalDays = repetitionCount <= 1 ? 3 : min(Self.maxIntervalDays, intervalDays * easeFactor * 1.3)
            dueDate = Calendar.current.date(byAdding: .day, value: max(1, Int(intervalDays.rounded())), to: now) ?? now
        }
    }
}

struct FlashcardSet: Identifiable, Codable {
    var id = UUID()
    var title: String
    var createdAt: Date = Date()
    var cards: [Flashcard]
}

struct ChatSession: Identifiable, Codable {
    let id: UUID
    var title: String
    var messages: [ChatMessage] = []
    var date = Date()
    var archiveFolder: String?
    var flashcards: [Flashcard]? // Deprecated
    var flashcardSets: [FlashcardSet]?
    /// Optional statt `Bool` mit Default, damit bereits gespeicherte Sessions ohne dieses Feld
    /// weiterhin sauber dekodiert werden (Swifts synthetisierter Decodable-Init ignoriert
    /// Default-Werte bei fehlendem Schlüssel, behandelt fehlende Optionals aber als nil).
    var isPinned: Bool?

    // Gibt das Datum der letzten Aktivität zurück (die letzte Nachricht oder das Erstelldatum)
    var lastActivityDate: Date {
        if let lastMessage = messages.last, let ts = lastMessage.timestamp {
            return ts
        }
        return date
    }

    init(id: UUID = UUID(), title: String, messages: [ChatMessage] = [], archiveFolder: String? = nil, flashcards: [Flashcard]? = nil, flashcardSets: [FlashcardSet]? = nil, isPinned: Bool? = nil) {
        self.id = id; self.title = title; self.messages = messages; self.archiveFolder = archiveFolder; self.flashcards = flashcards; self.flashcardSets = flashcardSets; self.isPinned = isPinned
    }
}
