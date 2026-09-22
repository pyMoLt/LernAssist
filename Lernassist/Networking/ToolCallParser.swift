import Foundation

// MARK: - ToolCallParser

/// Zweistufiges Tool-Call-Parsing gemäß FINDINGS.md §2:
/// 1. Primär: OpenAI-`tool_calls`-Feld (wird vom StreamingDelegate bereits geliefert)
/// 2. Fallback: Inline-JSON/XML im Content oder <think>-Block
///
/// Der Fallback-Parser erkennt drei gängige Muster kleiner Modelle:
/// - JSON-Objekt: `{"name": "web_search", "arguments": {"query": "..."}}`
/// - XML-Stil:    `<tool_call>{"name": ..., "arguments": {...}}</tool_call>`
/// - Hermes-Stil: `<tool_call>{"name":..., "parameters":{...}}</tool_call>`
///
/// Wichtig: Erkannte Inline-Calls werden aus dem Content/Thinking *herausgeschnitten*,
/// damit der Nutzer kein rohe JSON-Fragment sieht.
enum ToolCallParser {

    // MARK: - Inline-Parsing

    struct ParsedCall {
        let name: String
        let arguments: String  // JSON-String
        // Audit 2.7: `remainingText` war totes Feld (nur geschrieben, nie gelesen) – entfernt.
    }

    /// Sucht im gegebenen Text nach Inline-Tool-Calls und gibt alle gefundenen zurück.
    static func extractInlineCalls(from text: String) -> (calls: [ParsedCall], cleaned: String) {
        var result: [ParsedCall] = []
        var cleaned = text

        // 1. XML-Tag-Stil: <tool_call>...</tool_call>
        cleaned = extractXMLStyleCalls(from: cleaned, results: &result)

        // 2. JSON-Objekt-Stil: {"name": "...", "arguments": {...}}
        cleaned = extractJSONStyleCalls(from: cleaned, results: &result)

        return (result, cleaned.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - XML-Stil

    private static func extractXMLStyleCalls(from text: String, results: inout [ParsedCall]) -> String {
        var s = text
        let openTag = "<tool_call>"
        let closeTag = "</tool_call>"
        var scanStart = s.startIndex

        while let openRange = s.range(of: openTag, range: scanStart..<s.endIndex),
              let closeRange = s.range(of: closeTag, range: openRange.upperBound..<s.endIndex) {
            let jsonFragment = String(s[openRange.upperBound..<closeRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let call = parseCallJSON(jsonFragment) {
                // Audit H4: Registry-Validierung auch für den XML-Stil (wie beim JSON-Objekt-Stil).
                // Ein halluzinierter Tool-Name verbrennt sonst eine ganze Tool-Runde mit einem
                // "unbekanntes Tool"-Ergebnis, das das kleine Modell verwirrt. Der Marker bleibt
                // bewusst im Text stehen (sichtbar, statt still verschluckt zu werden) und die
                // Suche läuft weiter – echte Calls im Thinking-Block werden weiterhin erkannt.
                guard ToolRegistry.shared.tool(named: call.name) != nil else {
                    scanStart = closeRange.upperBound
                    continue
                }
                let fullRange = openRange.lowerBound..<closeRange.upperBound
                results.append(ParsedCall(name: call.name, arguments: call.args))
                let removalStart = openRange.lowerBound
                s.removeSubrange(fullRange)
                scanStart = removalStart
            } else {
                // Kaputtes JSON → nicht löschen, aber auch nicht weiter suchen
                break
            }
        }
        return s
    }

    // MARK: - JSON-Objekt-Stil

    /// Maximale Anzahl an "übrig gebliebenen" Nicht-JSON-Zeichen, bei der ein Fund noch als
    /// echter Tool-Call gilt (erlaubt z.B. ```json-Codezäune drumherum).
    private static let maxSurroundingProseLength = 60

    private static func extractJSONStyleCalls(from text: String, results: inout [ParsedCall]) -> String {
        guard text.contains("\"name\"") else { return text }

        // Phase 1: Alle plausiblen Kandidaten finden, OHNE sie sofort zu übernehmen.
        // Grund: Ein Modell, das in Fließtext erklärt/wiederholt, welches Tool es gerade
        // aufgerufen hat ("Ich habe {"name": "coding_sandbox", ...} genutzt, um..."), würde
        // sonst denselben Call ein zweites Mal auslösen (beobachteter Re-Trigger-Loop-Bug).
        var candidates: [(range: Range<String.Index>, call: CallJSON)] = []
        let s = text
        var searchStart = s.startIndex

        while searchStart < s.endIndex {
            guard let braceStart = s[searchStart...].firstIndex(of: "{") else { break }

            var depth = 0
            var idx = braceStart
            var braceEnd: String.Index? = nil
            while idx < s.endIndex {
                if s[idx] == "{" { depth += 1 }
                else if s[idx] == "}" {
                    depth -= 1
                    if depth == 0 { braceEnd = idx; break }
                }
                idx = s.index(after: idx)
            }

            guard let end = braceEnd else { break }
            let fragment = String(s[braceStart...end])

            if let call = parseCallJSON(fragment),
               ToolRegistry.shared.tool(named: call.name) != nil {
                candidates.append((braceStart..<s.index(after: end), call))
                searchStart = s.index(after: end)
            } else {
                searchStart = s.index(after: end)
            }
        }

        guard !candidates.isEmpty else { return text }

        // Phase 2: Nur übernehmen, wenn der Text im Wesentlichen NUR aus den JSON-Blöcken besteht
        // (echter Tool-Call), nicht wenn er in längerem Fließtext eingebettet ist (Erklärung/Narration).
        var withoutCandidates = s
        for (range, _) in candidates.reversed() {
            withoutCandidates.removeSubrange(range)
        }
        let leftoverProse = withoutCandidates.trimmingCharacters(in: .whitespacesAndNewlines)
        guard leftoverProse.count <= maxSurroundingProseLength else { return text }

        for (_, call) in candidates {
            results.append(ParsedCall(name: call.name, arguments: call.args))
        }
        return withoutCandidates
    }

    // MARK: - JSON → (name, arguments)

    private struct CallJSON {
        let name: String
        let args: String
    }

    private static func parseCallJSON(_ json: String) -> CallJSON? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String else { return nil }

        // arguments oder parameters
        let argsObj = obj["arguments"] ?? obj["parameters"]
        let argsString: String
        if let argsDict = argsObj as? [String: Any],
           let argsData = try? JSONSerialization.data(withJSONObject: argsDict),
           let argsStr = String(data: argsData, encoding: .utf8) {
            argsString = argsStr
        } else if let argsStr = argsObj as? String {
            argsString = argsStr
        } else {
            argsString = "{}"
        }

        return CallJSON(name: name, args: argsString)
    }

    // MARK: - (entfernt: accumulate)
    // Audit 2.7: `accumulate` hatte 0 Aufrufer (StreamingDelegate akkumuliert Deltas selbst) –
    // toter Code, entfernt.
}
