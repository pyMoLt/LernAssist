import Foundation

/// Ein Eintrag im Fehlerlog: falsch beantwortete Quizfrage oder mit „Nochmal“ bewertete Karte.
/// Aus offenen Einträgen entsteht das „Training aus Fehlern“.
struct MistakeEntry: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case quiz, flashcard }

    var id = UUID()
    var kind: Kind
    var date = Date()
    var sessionId: UUID?
    var subject: String?
    var question: String
    var givenAnswer: String?
    var correctAnswer: String?
    var explanation: String?
    /// Karte, zu der der Eintrag gehört (verhindert Dubletten bei mehrfachem „Nochmal“).
    var flashcardId: UUID?
    /// Wie oft derselbe Fehler auftrat.
    var count = 1
    var isResolved = false
}

/// Persistenz des Fehlerlogs (`mistakes.json` in der App-Ablage).
enum MistakeStore {
    static var fileURL: URL { AppStorageLocation.root.appendingPathComponent("mistakes.json") }

    static func load() -> [MistakeEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([MistakeEntry].self, from: data)) ?? []
    }

    static func save(_ entries: [MistakeEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? AppStorageLocation.writeAtomically(data, to: fileURL)
    }

    /// Fügt einen Fehler hinzu oder zählt einen gleichen offenen Eintrag hoch.
    static func merging(_ entry: MistakeEntry, into entries: [MistakeEntry]) -> [MistakeEntry] {
        var result = entries
        if let index = result.firstIndex(where: { existing in
            !existing.isResolved && (
                (entry.flashcardId != nil && existing.flashcardId == entry.flashcardId)
                || (existing.kind == entry.kind && existing.question == entry.question))
        }) {
            result[index].count += 1
            result[index].date = entry.date
            result[index].givenAnswer = entry.givenAnswer ?? result[index].givenAnswer
        } else {
            result.insert(entry, at: 0)
        }
        // Begrenzen: erledigte, alte Einträge fallen zuerst weg.
        if result.count > 500 {
            let resolved = result.enumerated().filter { $0.element.isResolved }.map(\.offset)
            for index in resolved.reversed().prefix(result.count - 500) { result.remove(at: index) }
            if result.count > 500 { result = Array(result.prefix(500)) }
        }
        return result
    }
}
