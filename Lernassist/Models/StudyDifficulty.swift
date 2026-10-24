import Foundation

/// Schwierigkeit der Abfragen im Chat (`quiz_card`) und der erzeugten Karteikarten. Jede Stufe hat
/// eine konkrete Beschreibung für das Modell – eine bloße Stufenbezeichnung bliebe wirkungslos.
nonisolated enum StudyDifficulty: String, Codable, CaseIterable, Identifiable, Sendable {
    case easy, medium, hard, veryHard

    var id: String { rawValue }

    var label: String {
        switch self {
        case .easy: L("Leicht")
        case .medium: L("Mittel")
        case .hard: L("Schwer")
        case .veryHard: L("Sehr schwer")
        }
    }

    /// Anweisung für Abfragen im Chat.
    var quizGuidance: String {
        switch self {
        case .easy:
            "Grundwissen: Definitionen, Fakten und Begriffe wiedererkennen; eindeutige Fragen, Ablenker klar unterscheidbar."
        case .medium:
            "Verständnis: Zusammenhänge, Mechanismen und Ursache-Wirkung; plausible Ablenker."
        case .hard:
            "Anwendung: kurze Fallvignetten und Szenarien, Wissen auf neue Situationen übertragen; Ablenker nah an der richtigen Antwort."
        case .veryHard:
            "Examensniveau: mehrschrittiges Denken, mehrere Themen verknüpfen, Ausnahmen und Feinheiten; alle Optionen plausibel."
        }
    }

    /// Anweisung für erzeugte Karteikarten.
    var cardGuidance: String {
        switch self {
        case .easy:
            "Einfache Faktenfragen: Definitionen, Begriffe, einzelne Zahlen oder Namen."
        case .medium:
            "Verständnisfragen: Warum und Wie, Zusammenhänge und Mechanismen in eigenen Worten."
        case .hard:
            "Anwendungsfragen: kurze Fälle oder Situationen, in denen das Wissen angewendet werden muss."
        case .veryHard:
            "Transferfragen auf Examensniveau: mehrere Schritte oder Themen verknüpfen, Ausnahmen und Abgrenzungen."
        }
    }

    /// Erkennt eine Stufe in einem Wort bzw. Wortpaar („schwer“, „sehr schwer“, „sehr-schwer“).
    static func parse(_ text: String) -> StudyDifficulty? {
        switch text.lowercased().replacingOccurrences(of: "-", with: " ") {
        case "leicht", "einfach", "easy": .easy
        case "mittel", "normal", "medium": .medium
        case "schwer", "schwierig", "hard": .hard
        case "sehr schwer", "sehrschwer", "extrem", "examen", "very hard": .veryHard
        default: nil
        }
    }
}
