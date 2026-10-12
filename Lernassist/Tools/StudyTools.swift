import Foundation

/// Ein Screenshot aus dem aktuellen Chat, wie ihn `recall_screenshot` sieht.
struct ChatScreenshot {
    let number: Int
    let base64: String
    let caption: String
}

// MARK: - recall_screenshot

/// Holt einen früheren Screenshot dieses Chats erneut als Bild für das Modell. Ältere Screenshots
/// gehen sonst nur als Textbeschreibung mit (spart Kontext/Bandbreite remote) – mit diesem Tool
/// kann das Modell eine Folie gezielt wieder „ansehen“, z. B. für Vergleiche.
final class RecallScreenshotTool: AppTool {
    let name = "recall_screenshot"
    let displayName = "Frühere Screenshots abrufen"
    let description = """
Holt einen früheren Screenshot aus diesem Chat erneut als Bild, wenn du ihn genau ansehen musst \
(z. B. „vergleiche mit der Folie von vorhin“). Screenshots sind im Verlauf als [Screenshot #N] \
markiert. number = Nummer des Screenshots; ohne number kommt der vorletzte.
"""
    let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "number": ["type": "integer", "minimum": 1, "description": "Nummer des Screenshots (#N im Verlauf)"]
        ],
        "required": [String]()
    ]
    var isEnabled: Bool = true

    /// Liefert die Screenshots einer Session (vom ViewModel gesetzt).
    var screenshotProvider: (String?) -> [ChatScreenshot] = { _ in [] }

    func run(arguments: String, sessionID: String?) async -> ToolResult {
        let shots = screenshotProvider(sessionID)
        guard !shots.isEmpty else {
            return .failure("In diesem Chat gibt es keine Screenshots.")
        }
        let requested = ToolArguments.nonNegativeInt(ToolArguments.object(arguments), "number")
        let target: ChatScreenshot?
        if let requested {
            target = shots.first { $0.number == requested }
        } else {
            target = shots.count >= 2 ? shots[shots.count - 2] : shots.last
        }
        guard let target else {
            return .failure("Screenshot #\(requested ?? 0) gibt es nicht. Vorhanden: #1 bis #\(shots.count).")
        }
        return ToolResult(content: "Screenshot #\(target.number) wird dir als Bild angehängt. \(target.caption)",
                          artifacts: [.modelImage(base64: target.base64,
                                                  caption: "[Screenshot #\(target.number), erneut abgerufen]")])
    }
}

// MARK: - quiz_card

/// Zeigt eine interaktive Abfragekarte im Chat (Multiple Choice oder Freitext). Die Antwort des
/// Nutzers kommt als nächste Nachricht zurück; danach gibt das Modell Feedback.
final class QuizCardTool: AppTool {
    let name = "quiz_card"
    let displayName = "Abfragekarte (Quiz)"
    let description = """
Stellt dem Nutzer eine Abfrage als interaktive Karte (Multiple Choice oder Freitext) – ideal im \
Tutor-Modus, um Verständnis zu prüfen. Nach dem Aufruf NICHT weiterschreiben: Die App wartet auf \
die Antwort des Nutzers und schickt sie dir; dann gib kurzes Feedback. Eine Frage pro Karte.
"""
    let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "question": ["type": "string", "description": "Die Frage (kurz, eindeutig)"],
            "options": ["type": "array", "items": ["type": "string"], "description": "2–6 Antwortoptionen; leer lassen für Freitext"],
            "correct_option": ["type": "integer", "minimum": 1, "description": "Optional: Nummer der richtigen Option (1 = erste)"],
            "explanation": ["type": "string", "description": "Optional: Erklärung, die nach der Antwort gezeigt wird"],
            "hint": ["type": "string", "description": "Optional: Hinweis, den der Nutzer aufdecken kann"]
        ],
        "required": ["question"]
    ]
    var isEnabled: Bool = true

    func run(arguments: String, sessionID: String?) async -> ToolResult {
        let args = ToolArguments.object(arguments)
        let question = ToolArguments.string(args, "question")
        guard !question.isEmpty else {
            return .failure("Fehler: `question` fehlt.")
        }
        let options = ((args["options"] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard options.isEmpty || (2...6).contains(options.count) else {
            return .failure("Fehler: Gib 2–6 Antwortoptionen an oder keine (Freitext).")
        }
        var correct: Int? = nil
        if let value = ToolArguments.nonNegativeInt(args, "correct_option"), value >= 1, value <= options.count {
            correct = value - 1
        }
        let card = QuizCard(question: question, options: options, correctIndex: correct,
                            explanation: ToolArguments.string(args, "explanation").nilIfEmpty,
                            hint: ToolArguments.string(args, "hint").nilIfEmpty)
        return ToolResult(content: "Die Abfragekarte wird angezeigt. Warte auf die Antwort des Nutzers – schreib jetzt nichts weiter.",
                          artifacts: [.quiz(card)])
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
