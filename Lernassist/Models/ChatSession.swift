import Foundation

struct Flashcard: Identifiable, Codable, Equatable {
    var id = UUID()
    var front: String
    var back: String
    /// Nächster Fälligkeitszeitpunkt. Frisch erstellte Karten sind sofort fällig.
    var dueDate: Date = Date()
    var intervalDays: Double = 0
    /// Altfeld aus dem SM-2-Scheduler, nur noch für die Übernahme alter Karten.
    var easeFactor: Double = 2.5
    var repetitionCount: Int = 0
    var lastReviewedAt: Date? = nil
    /// FSRS: Stabilität in Tagen (nil = neue Karte bzw. alte SM-2-Karte vor der Übernahme).
    var stability: Double? = nil
    /// FSRS: Schwierigkeit 1–10.
    var difficulty: Double? = nil
    /// Wie oft die Karte nach dem Lernen wieder vergessen wurde.
    var lapses: Int = 0
    /// Antwort, aus der die Karte entstand („Als Karte merken“).
    var sourceMessageId: UUID? = nil
    /// Abdeckkarte: Bild (ImageStore-ID) und verdeckter Bereich (x, y, Breite, Höhe; 0…1).
    var imageID: UUID? = nil
    var occlusion: [Double]? = nil

    private enum CodingKeys: String, CodingKey {
        case id, front, back, dueDate, intervalDays, easeFactor, repetitionCount, lastReviewedAt
        case stability, difficulty, lapses, sourceMessageId, imageID, occlusion
    }

    init(id: UUID = UUID(), front: String, back: String, dueDate: Date = Date(),
         intervalDays: Double = 0, easeFactor: Double = 2.5, repetitionCount: Int = 0,
         lastReviewedAt: Date? = nil, sourceMessageId: UUID? = nil,
         imageID: UUID? = nil, occlusion: [Double]? = nil) {
        self.id = id
        self.front = front
        self.back = back
        self.dueDate = dueDate
        self.intervalDays = intervalDays
        self.easeFactor = easeFactor
        self.repetitionCount = repetitionCount
        self.lastReviewedAt = lastReviewedAt
        self.sourceMessageId = sourceMessageId
        self.imageID = imageID
        self.occlusion = occlusion
    }

    /// Custom Decoder: fehlende Felder (ältere Karten) bekommen Standardwerte, statt dass die
    /// ganze Session beim Laden verworfen wird.
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
        stability = try c.decodeIfPresent(Double.self, forKey: .stability)
        difficulty = try c.decodeIfPresent(Double.self, forKey: .difficulty)
        lapses = try c.decodeIfPresent(Int.self, forKey: .lapses) ?? 0
        sourceMessageId = try c.decodeIfPresent(UUID.self, forKey: .sourceMessageId)
        imageID = try c.decodeIfPresent(UUID.self, forKey: .imageID)
        occlusion = try c.decodeIfPresent([Double].self, forKey: .occlusion)
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
        try c.encodeIfPresent(stability, forKey: .stability)
        try c.encodeIfPresent(difficulty, forKey: .difficulty)
        if lapses > 0 { try c.encode(lapses, forKey: .lapses) }
        try c.encodeIfPresent(sourceMessageId, forKey: .sourceMessageId)
        try c.encodeIfPresent(imageID, forKey: .imageID)
        try c.encodeIfPresent(occlusion, forKey: .occlusion)
    }
}

// MARK: - Spaced Repetition (FSRS, siehe FSRS.swift)

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
    /// Ist die Karte schon einmal gelernt worden?
    var isNew: Bool { stability == nil && repetitionCount == 0 }

    /// Plant die nächste Wiederholung nach FSRS-5. Alte SM-2-Karten werden beim ersten Review
    /// übernommen: bisheriges Intervall ≈ Stabilität, Ease-Faktor → Schwierigkeit.
    mutating func applyReview(_ rating: FlashcardRating, now: Date = Date(), scheduler: FSRS = FSRS(), againDelayMinutes: Int = 10) {
        let grade = rating.grade
        let elapsed = lastReviewedAt.map { now.timeIntervalSince($0) / 86_400 } ?? 0

        if stability == nil, repetitionCount > 0 {
            stability = max(0.5, intervalDays)
            // Ease 1,3 (schwer) … 3,0 (leicht) → Schwierigkeit 10 … 1
            difficulty = min(10, max(1, 10 - (easeFactor - 1.3) / 1.7 * 9))
        }

        if let s = stability, let d = difficulty {
            let r = scheduler.retrievability(elapsedDays: elapsed, stability: s)
            if elapsed < 1 {
                stability = scheduler.shortTermStability(s: s, grade: grade)
            } else if grade == 1 {
                stability = scheduler.stabilityAfterForgetting(s: s, d: d, r: r)
            } else {
                stability = scheduler.stabilityAfterSuccess(s: s, d: d, r: r, grade: grade)
            }
            difficulty = scheduler.nextDifficulty(d, grade: grade)
        } else {
            stability = scheduler.initialStability(grade)
            difficulty = scheduler.initialDifficulty(grade)
        }

        lastReviewedAt = now
        if grade == 1 {
            if repetitionCount > 0 { lapses += 1 }
            repetitionCount = 0
            intervalDays = 0
            // Vergessen: nach N Minuten in derselben Sitzung noch einmal.
            dueDate = now.addingTimeInterval(Double(max(1, againDelayMinutes) * 60))
        } else {
            repetitionCount += 1
            intervalDays = scheduler.interval(stability: stability ?? 1)
            dueDate = Calendar.current.date(byAdding: .day, value: Int(intervalDays), to: now) ?? now
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
    /// Fach-Etikett (z. B. „Physiologie“, „Algorithmen“) – von der KI vergeben oder selbst gesetzt.
    var subject: String?
    /// Titel und Fach wurden nach einigen Nachrichten noch einmal überprüft (Fokus kann wandern).
    var titleRefined: Bool?
    /// Fach wurde von Hand gesetzt – die KI überschreibt es dann nicht mehr.
    var subjectSetByUser: Bool?

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
