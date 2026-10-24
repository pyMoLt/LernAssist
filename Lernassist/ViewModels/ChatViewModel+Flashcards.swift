import Foundation
import Combine
import os

/// Hinweis nach „Als Karte merken“ – mit Rückgängig.
struct FlashcardNotice: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let sessionId: UUID
    let setId: UUID
    let cardIds: [UUID]
    var isError = false
}

extension ChatViewModel {
    /// Titel des Sets, in dem gemerkte Karten eines Chats landen.
    static let rememberedSetTitle = "Gemerkte Karten"

    // MARK: - Fälligkeits-Index

    /// Baut die Liste der Fälligkeitszeitpunkte neu auf (nur Karten, keine Nachrichten) und
    /// plant die nächste Aktualisierung genau dann, wenn die nächste Karte fällig wird.
    func refreshFlashcardIndex() {
        var dates: [Date] = []
        for session in sessions + archivedSessions {
            for set in session.flashcardSets ?? [] {
                dates.append(contentsOf: set.cards.map(\.dueDate))
            }
        }
        flashcardDueDates = dates
        updateDueFlashcardsCount()
    }

    func updateDueFlashcardsCount() {
        let now = Date()
        let count = flashcardDueDates.filter { $0 <= now }.count
        if count != dueFlashcardsCount { dueFlashcardsCount = count }
        flashcardRefreshTimer?.invalidate()
        if let next = flashcardDueDates.filter({ $0 > now }).min() {
            let delay = min(max(next.timeIntervalSince(now) + 1, 5), 3600)
            flashcardRefreshTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateDueFlashcardsCount() }
            }
        }
    }

    /// Hält den Index aktuell, ohne jede Mutation einzeln abfangen zu müssen.
    func setupFlashcardIndex() -> AnyCancellable {
        refreshFlashcardIndex()
        return Publishers.CombineLatest($sessions, $archivedSessions)
            .map { sessions, archived in
                (sessions + archived).flatMap { ($0.flashcardSets ?? []).flatMap { $0.cards.map(\.dueDate) } }
            }
            .removeDuplicates()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] dates in
                self?.flashcardDueDates = dates
                self?.updateDueFlashcardsCount()
            }
    }

    // MARK: - Fehlerlog

    func recordMistake(_ entry: MistakeEntry) {
        mistakes = MistakeStore.merging(entry, into: mistakes)
        MistakeStore.save(mistakes)
    }

    func setMistakeResolved(_ id: UUID, resolved: Bool = true) {
        guard let index = mistakes.firstIndex(where: { $0.id == id }) else { return }
        mistakes[index].isResolved = resolved
        MistakeStore.save(mistakes)
    }

    func deleteMistake(_ id: UUID) {
        mistakes.removeAll { $0.id == id }
        MistakeStore.save(mistakes)
    }

    func removeResolvedMistakes() {
        mistakes.removeAll { $0.isResolved }
        MistakeStore.save(mistakes)
    }

    var openMistakes: [MistakeEntry] { mistakes.filter { !$0.isResolved } }

    /// „Training aus Fehlern“: Ein neuer Chat fragt genau die offenen Fehler ab – variiert, als
    /// Quizkarten, eine nach der anderen.
    func startMistakeTraining(subject: String? = nil) {
        let open = openMistakes.filter { subject == nil || $0.subject == subject }.prefix(12)
        guard !open.isEmpty else { return }
        let list = open.enumerated().map { index, entry in
            var line = "\(index + 1). \(entry.question)"
            if let correct = entry.correctAnswer, !correct.isEmpty { line += " — richtig: \(correct)" }
            if let given = entry.givenAnswer, !given.isEmpty { line += " — meine Antwort war: \(given)" }
            return line
        }.joined(separator: "\n")
        createNewChat()
        if let idx = sessions.firstIndex(where: { $0.id == activeSessionId }) {
            sessions[idx].title = "Training aus Fehlern"
            sessions[idx].subject = subject ?? open.first?.subject
        }
        sendMessage(text: """
            Trainiere mit mir meine Fehler. Das sind Fragen, die ich falsch beantwortet oder vergessen habe:
            \(list)

            Stelle mir dazu nacheinander neue, leicht abgewandelte Fragen (nicht wörtlich dieselben), jede als \
            `quiz_card`. Warte jeweils auf meine Antwort, erkläre kurz, warum die richtige Antwort stimmt, und \
            gehe dann zur nächsten. Mische die Reihenfolge. Am Ende fasse kurz zusammen, was noch unsicher ist.
            """, displayText: "Training aus Fehlern (\(open.count))")
    }

    // MARK: - Karten verwalten

    /// Fügt Karten in ein Set eines Chats ein (legt es bei Bedarf an) und gibt die Set-ID zurück.
    @discardableResult
    func addFlashcards(_ cards: [Flashcard], to sessionId: UUID, setTitle: String) -> UUID? {
        guard !cards.isEmpty, let session = (sessions + archivedSessions).first(where: { $0.id == sessionId }) else { return nil }
        var sets = session.flashcardSets ?? []
        let setId: UUID
        if let index = sets.firstIndex(where: { $0.title == setTitle }) {
            sets[index].cards.append(contentsOf: cards)
            setId = sets[index].id
        } else {
            let set = FlashcardSet(title: setTitle, cards: cards)
            sets.insert(set, at: 0)
            setId = set.id
        }
        updateFlashcardSets(for: sessionId, sets: sets)
        refreshFlashcardIndex()
        return setId
    }

    func updateFlashcard(sessionId: UUID, setId: UUID, card: Flashcard) {
        guard var sets = (sessions + archivedSessions).first(where: { $0.id == sessionId })?.flashcardSets,
              let setIndex = sets.firstIndex(where: { $0.id == setId }),
              let cardIndex = sets[setIndex].cards.firstIndex(where: { $0.id == card.id }) else { return }
        // Bild im Editor entfernt: die Kopie der Karte mit löschen.
        if let oldImage = sets[setIndex].cards[cardIndex].imageID, card.imageID != oldImage {
            ImageStore.shared.removeImage(for: oldImage)
            try? FileManager.default.removeItem(at: AppStorageLocation.imageFile(id: oldImage))
        }
        sets[setIndex].cards[cardIndex] = card
        updateFlashcardSets(for: sessionId, sets: sets)
    }

    func deleteFlashcards(sessionId: UUID, setId: UUID, cardIds: [UUID]) {
        guard var sets = (sessions + archivedSessions).first(where: { $0.id == sessionId })?.flashcardSets,
              let setIndex = sets.firstIndex(where: { $0.id == setId }) else { return }
        // Bilder von Karteikarten sind immer eigene Kopien (siehe storeCardImage) – sie gehen mit.
        let imageIDs = sets[setIndex].cards.filter { cardIds.contains($0.id) }.compactMap(\.imageID)
        sets[setIndex].cards.removeAll { cardIds.contains($0.id) }
        if sets[setIndex].cards.isEmpty { sets.remove(at: setIndex) }
        for id in imageIDs {
            ImageStore.shared.removeImage(for: id)
            try? FileManager.default.removeItem(at: AppStorageLocation.imageFile(id: id))
        }
        updateFlashcardSets(for: sessionId, sets: sets)
        refreshFlashcardIndex()
    }

    // MARK: - Karten erzeugen

    private static func flashcardSchema(withImage: Bool) -> [String: Any] {
        var properties: [String: Any] = ["front": ["type": "string"], "back": ["type": "string"]]
        var required = ["front", "back"]
        if withImage {
            properties["image"] = ["type": "integer"]
            required.append("image")
        }
        return [
            "type": "object",
            "properties": ["cards": ["type": "array", "items": [
                "type": "object", "properties": properties,
                "required": required, "additionalProperties": false]]],
            "required": ["cards"], "additionalProperties": false]
    }

    /// Höchstens so viele Bildkarten pro Chat.
    static let maxImageCardsPerChat = 3

    /// Lässt das Modell Karten erzeugen (strukturierte Ausgabe mit Fallback-Parser).
    /// Gibt nil zurück, wenn der Endpunkt nicht erreichbar war, [] bei unbrauchbarer Antwort.
    /// Mit `images` darf höchstens eine Karte ein Bild nutzen – nur wenn das Bild selbst Lernstoff
    /// ist (`GeneratedCard.image` = Nummer des Bildes).
    func generateFlashcards(instruction: String, context: String, images: [String] = []) async -> [GeneratedCard]? {
        let imageRule = images.isEmpty ? "" : """

        Dir liegen \(images.count == 1 ? "1 Bild" : "\(images.count) Bilder") aus dieser Frage und Antwort vor \
        (Bild 1\(images.count > 1 ? " bis \(images.count)" : "")). Ist ein Bild selbst Lernstoff (z. B. Histologie, EKG, \
        Röntgen, Anatomie, Schema, Diagramm, Plot), darf GENAU EINE Karte es nutzen: Setze bei ihr "image" auf die \
        Nummer des Bildes und stelle die Frage zum Bild (z. B. „Welche Struktur ist markiert?“, „Welcher Rhythmus liegt \
        vor?“). Zeigt ein Bild nur Text (z. B. Folientext), nutze es nicht. Alle anderen Karten: "image": 0.
        """
        let format = images.isEmpty ? #"{"cards": [{"front": "…", "back": "…"}]}"# : #"{"cards": [{"front": "…", "back": "…", "image": 0}]}"#
        let prompt = """
        \(instruction)
        Eine Aussage pro Karte. Vorderseite: präzise Frage. Rückseite: kurze, korrekte Antwort \
        (1–3 Sätze, Fachbegriffe beibehalten). Sprache wie im Kontext.
        Schwierigkeit: \(flashcardDifficulty.label) – \(flashcardDifficulty.cardGuidance)\(imageRule)

        Kontext:
        \(context)

        Antworte nur mit JSON: \(format)
        """
        let imageMessages = images.enumerated().map { index, base64 in
            ChatMessage(role: "user", content: "Bild \(index + 1)", imageBase64: base64)
        }
        guard let result = await sendInvisiblePrompt(prompt, context: imageMessages,
                                                     jsonSchema: ("flashcards", Self.flashcardSchema(withImage: !images.isEmpty))) else {
            return nil
        }
        return Self.parseGeneratedCards(result, imageCount: images.count)
    }

    struct GeneratedCard {
        var card: Flashcard
        /// Nummer des Bildes (1…n), das zur Karte gehört; nil = reine Textkarte.
        var image: Int?
    }

    /// Wie `parseFlashcards`, plus Bildnummer. Höchstens eine Karte behält ein (gültiges) Bild.
    static func parseGeneratedCards(_ raw: String, imageCount: Int) -> [GeneratedCard] {
        let cards = parseFlashcards(raw)
        guard imageCount > 0 else { return cards.map { GeneratedCard(card: $0, image: nil) } }
        struct ImageRef: Decodable { let image: Int? }
        var text = raw.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        if let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end {
            text = String(text[start...end])
        }
        let refs = (text.data(using: .utf8).flatMap { try? JSONDecoder().decode([ImageRef].self, from: $0) }) ?? []
        var imageUsed = false
        return cards.enumerated().map { index, card in
            let ref = index < refs.count ? refs[index].image : nil
            guard !imageUsed, let ref, (1...imageCount).contains(ref) else { return GeneratedCard(card: card, image: nil) }
            imageUsed = true
            return GeneratedCard(card: card, image: ref)
        }
    }

    /// Speichert ein Kartenbild als EIGENE Kopie: Die Karte bleibt vollständig, auch wenn die
    /// Nachricht mit dem Original später entfernt wird.
    static func storeCardImage(base64: String) -> UUID? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        let id = UUID()
        do {
            try data.write(to: AppStorageLocation.imageFile(id: id), options: .atomic)
            return id
        } catch {
            AppLog.persistence.error("Kartenbild konnte nicht gespeichert werden: \(error.localizedDescription)")
            return nil
        }
    }

    /// Bilder aus Frage und Antwort eines Turns: Screenshot der Frage, Plots und Bilder bis zur Antwort.
    static func turnImages(in messages: [ChatMessage], answerId: UUID) -> [String] {
        guard let answerIndex = messages.firstIndex(where: { $0.id == answerId }) else { return [] }
        let questionIndex = messages[..<answerIndex].lastIndex(where: { $0.role == "user" }) ?? answerIndex
        return messages[questionIndex...answerIndex].compactMap { imagePayloadBase64(for: $0) }
    }

    /// Wie viele Bildkarten ein Chat schon hat.
    func imageCardCount(in session: ChatSession) -> Int {
        (session.flashcardSets ?? []).reduce(0) { $0 + $1.cards.filter { $0.imageID != nil }.count }
    }

    /// Liest {"cards": [...]} oder ein nacktes Array – tolerant gegenüber Markdown-Resten.
    static func parseFlashcards(_ raw: String) -> [Flashcard] {
        struct Card: Decodable { let front: String; let back: String }
        var text = raw.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cards = object["cards"], let cardsData = try? JSONSerialization.data(withJSONObject: cards),
           let string = String(data: cardsData, encoding: .utf8) {
            text = string
        }
        if let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end {
            text = String(text[start...end])
        }
        text = text.replacingOccurrences(of: ",\\s*]", with: "]", options: .regularExpression)
        guard let data = text.data(using: .utf8), let cards = try? JSONDecoder().decode([Card].self, from: data) else { return [] }
        return cards
            .map { (front: $0.front.trimmingCharacters(in: .whitespacesAndNewlines), back: $0.back.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.front.isEmpty && !$0.back.isEmpty }
            .map { Flashcard(front: $0.front, back: $0.back) }
    }

    /// „Als Karte merken“: verdichtet eine Antwort (oder markierten Text daraus) zu 1–3 Karten im
    /// Set „Gemerkte Karten“ des Chats. Danach erscheint ein Hinweis mit Rückgängig.
    func rememberAsFlashcards(messageId: UUID, selectedText: String? = nil) {
        guard let session = sessions.first(where: { $0.messages.contains { $0.id == messageId } }),
              let message = session.messages.first(where: { $0.id == messageId }) else { return }
        let source = (selectedText?.isEmpty == false ? selectedText! : message.content)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Die Frage davor gibt dem Modell den Zusammenhang.
        let question = session.messages.prefix(while: { $0.id != messageId }).last(where: { $0.role == "user" })
        let context = (question.map { "Frage: \($0.displayText ?? $0.content)\n\n" } ?? "") + "Erklärung:\n" + String(source.prefix(8_000))
        let sessionId = session.id
        let cardBudget = max(1, min(5, flashcardCardsPerResponse))
        // Bildkarte: nur wenn Frage oder Antwort ein Bild enthält, höchstens eine pro Nachricht und
        // höchstens `maxImageCardsPerChat` pro Chat.
        let images = imageCardCount(in: session) < Self.maxImageCardsPerChat
            ? Array(Self.turnImages(in: session.messages, answerId: messageId).suffix(3)) : []
        backgroundJobStatus = "Erstelle Karteikarten …"
        Task {
            let generated = await generateFlashcards(
                instruction: "Verdichte diese Erklärung zu 1 bis \(cardBudget) Karteikarten mit den wichtigsten, prüfungsrelevanten Aussagen. Lieber weniger, dafür präzise.",
                context: context, images: images)
            let cards = generated?.map { item -> Flashcard in
                var card = item.card
                if let number = item.image, images.indices.contains(number - 1) {
                    card.imageID = Self.storeCardImage(base64: images[number - 1])
                }
                return card
            }
            if backgroundJobStatus == "Erstelle Karteikarten …" { backgroundJobStatus = nil }
            guard let cards, !cards.isEmpty else {
                flashcardNotice = FlashcardNotice(text: cards == nil ? "Karten konnten nicht erstellt werden – \(lastInvisiblePromptError ?? "Endpunkt nicht erreichbar")."
                                                                     : "Karten konnten nicht erstellt werden – bitte erneut versuchen.",
                                                  sessionId: sessionId, setId: UUID(), cardIds: [], isError: true)
                return
            }
            let tagged = cards.prefix(cardBudget).map { card -> Flashcard in
                var copy = card
                copy.sourceMessageId = messageId
                return copy
            }
            guard let setId = addFlashcards(Array(tagged), to: sessionId, setTitle: Self.rememberedSetTitle) else { return }
            flashcardNotice = FlashcardNotice(
                text: tagged.count == 1 ? "1 Karte gemerkt" : "\(tagged.count) Karten gemerkt",
                sessionId: sessionId, setId: setId, cardIds: tagged.map(\.id))
        }
    }

    /// Beantwortete Quizfrage direkt als Karte merken (ohne Modell): Frage → richtige Antwort + Erklärung.
    func rememberQuizCard(messageId: UUID) {
        guard let session = sessions.first(where: { $0.messages.contains { $0.id == messageId } }),
              let card = session.messages.first(where: { $0.id == messageId })?.quizCard else { return }
        var back = card.correctIndex.flatMap { card.options.indices.contains($0) ? card.options[$0] : nil }
            ?? card.freeTextAnswer ?? ""
        if let explanation = card.explanation, !explanation.isEmpty {
            back += back.isEmpty ? explanation : "\n\n" + explanation
        }
        guard !back.isEmpty else { return }
        let flashcard = Flashcard(front: card.question, back: back, sourceMessageId: messageId)
        guard let setId = addFlashcards([flashcard], to: session.id, setTitle: Self.rememberedSetTitle) else { return }
        flashcardNotice = FlashcardNotice(text: "1 Karte gemerkt", sessionId: session.id, setId: setId, cardIds: [flashcard.id])
    }

    func undoFlashcardNotice(_ notice: FlashcardNotice) {
        deleteFlashcards(sessionId: notice.sessionId, setId: notice.setId, cardIds: notice.cardIds)
        flashcardNotice = nil
    }
}
