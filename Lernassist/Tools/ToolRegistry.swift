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
            TerminalTool()
        ]
    }

    // MARK: - Aktive Tools

    var enabledTools: [AppTool] { tools.filter { $0.isEnabled } }

    /// OpenAI-kompatibles Schema-Array — nur für aktive Tools.
    var schemas: [[String: Any]] { enabledTools.map { $0.openAISchema } }

    /// Prompt-Erweiterung — nur für aktive Tools, mit Few-Shot-Hinweisen.
    var systemPromptAddition: String {
        guard !enabledTools.isEmpty else { return "" }
        let toolList = enabledTools.map { "- **\($0.name)**: \($0.description)" }.joined(separator: "\n")
        return """

---
**Verfügbare Tools** (nur nutzen wenn tatsächlich nötig — NICHT für triviale Rechenaufgaben wie 1+2, einfache Definitionen oder allgemeines Wissen):
\(toolList)

**Tool-Nutzungsregeln:**
- Nutze Tools bei Unsicherheit, Verifikationsbedarf oder aktuellen Fakten.
- Zitiere die Quelle in deiner Antwort (z.B. „Laut [Quelle] ...").
- Löse einfache Aufgaben direkt ohne Tool.
- Wenn ein Tool ein `<TOOL_ERROR>` zurückgibt, ist das zunächst eine faktische Rückmeldung. Lies die konkrete Ursache: Bei fehlerhaften Argumenten kannst du sie korrigieren oder ein geeignetes anderes Tool wählen; nach ausgeschöpften transienten Versuchen entscheidest du selbst, wie du sinnvoll fortfährst. Erfinde kein Ergebnis.
"""
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
