import Foundation
import os

// MARK: - ToolRegistry

/// Zentrale Registrierung aller verfügbaren Tools.
/// - Nur **aktivierte** Tools tauchen im API-Schema und im System-Prompt auf.
/// - Reihenfolge ist stabil (für KV-Cache-Reuse wichtig, s. FINDINGS.md §1).
final class ToolRegistry {
    static let shared = ToolRegistry()

    var currentSessionID: String?

    private(set) var tools: [AppTool]

    private init() {
        tools = [
            WebSearchTool(),
            BrowseURLTool(),
            CalculateTool(),
            CodingTool(),
            RecallScreenshotTool(),
            QuizCardTool()
        ]
    }

    // MARK: - Aktive Tools

    /// Standard-Schwierigkeit für `quiz_card` (Einstellungen → Lernen). Ändert den System-Prompt
    /// nur, wenn der Nutzer die Einstellung wechselt – nicht von Anfrage zu Anfrage.
    var quizDifficulty: StudyDifficulty = .medium

    var enabledTools: [AppTool] { tools.filter { $0.isEnabled } }

    /// OpenAI-kompatibles Schema-Array — nur für aktive Tools.
    var schemas: [[String: Any]] { enabledTools.map { $0.openAISchema } }

    /// Prompt-Erweiterung — nur für aktive Tools, mit Few-Shot-Hinweisen.
    /// Kurze Regeln für den System-Prompt. Die Tool-Beschreibungen stehen bereits im
    /// `tools`-Schema des Requests – sie hier zu wiederholen kostete ≈ 2,5k Tokens pro Anfrage
    /// (Audit 2026-10-12). Regeln nur für tatsächlich aktive Tools.
    var systemPromptAddition: String {
        let names = Set(enabledTools.map(\.name))
        guard !names.isEmpty else { return "" }
        var rules = ["Nutze Tools nur, wenn sie wirklich helfen – einfache Fragen beantwortest du direkt."]
        if names.contains("web_search") {
            rules.append("Bei Fakten, Zahlen, Leitlinien oder Aktuellem, bei denen du unsicher bist: `web_search` (führe keine redundanten Folgesuchen durch, sobald die benötigten Fakten vorliegen). Zitiere [W#] nur für Belege, die dir `web_search` in diesem Gespräch tatsächlich geliefert hat – ohne Suche keine [W#]-Angaben, und erfinde keine Quellen.")
        }
        if names.contains("coding_sandbox") {
            rules.append("Geht es um Datenauswertung, Berechnungen, Grafiken oder interaktive Darstellungen, führe Code mit `coding_sandbox` aus, statt ihn nur in den Chat zu schreiben – Python oder HTML, je nachdem was passt (typisch: Python für Daten und Plots, HTML/JS für Interaktives und Simulationen). Erzeugte oder gelieferte Grafiken erhalten eine `[B#]`-Nummer und werden mit `[B#]` in einer eigenen Zeile eingebunden. Geht es um den Code selbst (erklären, besprechen, üben), schreibe ihn in den Chat.")
        }
        if names.contains("recall_screenshot") {
            rules.append("Musst du eine frühere Folie genau ansehen, hole sie mit `recall_screenshot`.")
        }
        if names.contains("quiz_card") {
            rules.append("Will der Nutzer abgefragt oder getestet werden („frag mich ab“, „teste mich“, „Quiz“), jede Frage einzeln als `quiz_card` stellen (nicht als Text) und auf die Antwort warten; nach dem Feedback die nächste Frage wieder als `quiz_card`. Nennt er eine Anzahl, genau so viele Fragen, danach kurze Auswertung.")
            rules.append("Schwierigkeit der Abfragen: \(quizDifficulty.label) – \(quizDifficulty.quizGuidance) Nennt der Nutzer eine andere Stufe, gilt seine.")
        }
        rules.append("Meldet ein Tool <TOOL_ERROR>, lies die Ursache, korrigiere die Argumente oder fahre ohne Tool fort. Erfinde kein Ergebnis.")
        return "\n\n---\n**Tools:**\n" + rules.map { "- " + $0 }.joined(separator: "\n")
    }

    // MARK: - Tool per Name finden und ausführen

    func tool(named name: String) -> AppTool? {
        tools.first { $0.name == name }
    }

    // MARK: - App-seitiger Retry-Layer (Nutzer-Feature)

    /// Insgesamt 3 Versuche (1 original + 2 Wiederholungen), Backoff 1 s → 3 s mit Jitter.
    private static let maxToolAttempts = 3
    private static let retryDelays: [TimeInterval] = [1.0, 3.0]

    func execute(name: String, arguments: String, sessionID: String?) async -> ToolResult {
        guard let tool = tool(named: name), tool.isEnabled else {
            return .failure("Tool '\(name)' ist nicht verfügbar oder deaktiviert.")
        }
        // Ungültiges JSON kleiner Modelle (Python-Literale, Kommas am Ende, abgeschnitten …) reparieren.
        var arguments = arguments
        if !ToolArgumentRepair.isValid(arguments), let repaired = ToolArgumentRepair.repair(arguments) {
            AppLog.tools.info("Tool '\(name)': Argumente repariert")
            arguments = repaired
        }
        var result = await tool.run(arguments: arguments, sessionID: sessionID)
        var attempt = 1

        // Nur VORÜBERGEHENDE Fehler (Rate-Limit, 5xx, Timeout, Verbindungsabbruch) wiederholt
        // die App hier automatisch mit Abstand – nicht vom Modell selbst, sondern serverseitig
        // mit Jitter, damit sich parallele Retries nicht gegenseitig verstärken. Fatale Fehler
        // (Argumentfehler, blockiertes Scheme) gehen unverzüglich zurück: Das Modell muss sie
        // selbst korrigieren, Wiederholen wäre nur Latenz.
        while result.isError,
              result.errorKind == .transient,
              attempt < Self.maxToolAttempts,
              !Task.isCancelled {
            let delay = Self.retryDelays[min(attempt - 1, Self.retryDelays.count - 1)]
            let jitter = Double.random(in: 0...0.5)
            AppLog.tools.info("Tool '\(name)' vorübergehend fehlgeschlagen – automatischer Retry \(attempt + 1)/\(Self.maxToolAttempts) in \(String(format: "%.1f", delay + jitter)) s")
            try? await Task.sleep(nanoseconds: UInt64((delay + jitter) * 1_000_000_000))
            guard !Task.isCancelled else { break }
            result = await tool.run(arguments: arguments, sessionID: sessionID)
            attempt += 1
        }

        // Erschöpfter Retry: rein FAKTISCHE Rückmeldung an das Modell, bewusst OHNE Verhaltens-
        // Anweisung (Nutzer-Entscheidung): Ein imperatives „wiederhole nicht sofort" würde ein
        // kleines Modell dauerhaft konditionieren – auch eine Viertelstunde später, wenn das
        // Rate-Limit längst weg ist. Das Modell entscheidet selbst, wie es fortfährt.
        if result.isError, result.errorKind == .transient, attempt >= Self.maxToolAttempts {
            let exhausted = ToolResult(
                content: result.content
                    + "\n\n[Status: Die App hat diesen Aufruf automatisch \(attempt)-mal nach kurzer Wartezeit wiederholt, ohne Erfolg.]",
                isError: true,
                errorKind: .transient,
                source: result.source,
                artifacts: result.artifacts,
                includesCorrectionGuidance: false
            )
            return exhausted
        }
        return result
    }

    // MARK: - Persistenz (isEnabled pro Tool)

    func loadEnabledStates(from dict: [String: Bool]) {
        for tool in tools {
            if let enabled = dict[tool.name] { tool.isEnabled = enabled }
        }
    }

    func enabledStates() -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0.isEnabled) })
    }
}
