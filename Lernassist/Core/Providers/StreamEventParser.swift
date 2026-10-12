import Foundation

// MARK: - Stream-Ereignisse

/// Ein Ereignis aus einem gestreamten Chat-Completion-Response – unabhängig vom Provider-Format.
nonisolated enum LLMEvent: Equatable, Sendable {
    case content(String)
    case thinking(String)
    case toolCall(ToolCallInfo)
    case metrics(ChatMetrics)
    /// Der Server meldet das reguläre Ende ([DONE] bzw. `done: true`).
    case done
}

/// Wire-Format eines Streams.
nonisolated enum StreamWireFormat: Sendable {
    /// Server-Sent Events: `data: {...}` + `data: [DONE]` (OpenAI, LM Studio, oMLX, MLX, llama.cpp).
    case sse
    /// Newline-delimited JSON ohne Präfix, Ende über `"done": true` (Ollama /api/chat).
    case ndjson
}

/// Fehler, die der Server INNERHALB eines 200-Streams meldet (SSE-Fehler-Event).
nonisolated struct StreamServerError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Parser

/// Zustandsbehafteter, aber rein funktionaler Parser: bekommt vollständige Zeilen und liefert
/// Ereignisse. Kein Netzwerk, kein Threading – dadurch vollständig testbar.
///
/// Übernimmt die bewährte Logik des früheren `StreamingDelegate`:
/// - Metriken (`usage`/`timings`) werden unabhängig von `choices` gelesen (der usage-Chunk hat
///   laut OpenAI-Spec ein leeres `choices`-Array) und über die Runde akkumuliert.
/// - Reasoning kommt entweder als eigenes Feld (`reasoning_content`, `reasoning`, `thinking`) oder
///   inline als `<think>…</think>` im Content – Tags dürfen über Chunk-Grenzen verteilt sein.
/// - Tool-Calls im OpenAI- (`delta.tool_calls`) und Ollama-Format (`message.tool_calls`).
nonisolated struct StreamEventParser {
    let format: StreamWireFormat

    private var isThinking = false
    private var tagBuffer = ""
    private var accumulatedMetrics = ChatMetrics.empty
    private(set) var isDone = false

    init(format: StreamWireFormat) {
        self.format = format
    }

    /// Verarbeitet eine vollständige Zeile (ohne Zeilenumbruch).
    mutating func consume(line rawLine: String) throws -> [LLMEvent] {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !isDone else { return [] }

        switch format {
        case .ndjson:
            return try processJSON(line)
        case .sse:
            // SSE-Kommentare (": keep-alive") und event:-Zeilen tragen keine Nutzdaten.
            guard line.hasPrefix("data:") else { return [] }
            var payload = String(line.dropFirst(5))
            if payload.hasPrefix(" ") { payload.removeFirst() }
            if payload == "[DONE]" {
                var events = flush()
                isDone = true
                events.append(.done)
                return events
            }
            return try processJSON(payload)
        }
    }

    /// Gibt einen eventuell gepufferten Tag-Rest aus (Stream-Ende ohne `</think>`).
    mutating func flush() -> [LLMEvent] {
        var events: [LLMEvent] = []
        if !tagBuffer.isEmpty {
            events.append(isThinking ? .thinking(tagBuffer) : .content(tagBuffer))
            tagBuffer = ""
        }
        isThinking = false
        return events
    }

    // MARK: JSON

    private mutating func processJSON(_ text: String) throws -> [LLMEvent] {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        if let message = Self.serverErrorMessage(in: json) {
            throw StreamServerError(message: message)
        }

        var events: [LLMEvent] = []
        if let metrics = MetricsParser.parse(fromDict: json, mergingInto: accumulatedMetrics) {
            accumulatedMetrics = metrics
            events.append(.metrics(metrics))
        }

        if let choices = json["choices"] as? [[String: Any]],
           let delta = choices.first?["delta"] as? [String: Any] {
            events += toolCalls(from: delta["tool_calls"] as? [[String: Any]])
            if let thinking = Self.reasoningText(in: delta) {
                events.append(.thinking(thinking))
            }
            if let content = delta["content"] as? String, !content.isEmpty {
                events += processContent(content)
            }
            return events
        }

        if let message = json["message"] as? [String: Any] {
            events += toolCalls(from: message["tool_calls"] as? [[String: Any]])
            if let thinking = Self.reasoningText(in: message) {
                events.append(.thinking(thinking))
            }
            if let content = message["content"] as? String, !content.isEmpty {
                events += processContent(content)
            }
        }

        if format == .ndjson, json["done"] as? Bool == true {
            events += flush()
            isDone = true
            events.append(.done)
        }
        return events
    }

    private static func reasoningText(in object: [String: Any]) -> String? {
        let text = object["reasoning_content"] as? String
            ?? object["reasoning"] as? String
            ?? object["thinking"] as? String
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// Fehlermeldung eines Fehler-Objekts im Stream (`{"error": "..."}` bzw.
    /// `{"error": {"message": "..."}}` bzw. FastAPI `{"detail": "..."}`).
    static func serverErrorMessage(in json: [String: Any]) -> String? {
        if let error = json["error"] as? String, !error.isEmpty { return error }
        if let error = json["error"] as? [String: Any] {
            return (error["message"] as? String) ?? (error["type"] as? String) ?? "Unbekannter Serverfehler"
        }
        if json["choices"] == nil, json["message"] == nil, let detail = json["detail"] {
            if let text = detail as? String { return text }
            if let list = detail as? [[String: Any]] {
                return list.compactMap { $0["msg"] as? String }.joined(separator: "; ")
            }
        }
        return nil
    }

    private func toolCalls(from tools: [[String: Any]]?) -> [LLMEvent] {
        guard let tools else { return [] }
        return tools.map { tool in
            let function = tool["function"] as? [String: Any] ?? [:]
            let index = (tool["index"] as? Int) ?? (function["index"] as? Int)
            let id = (tool["id"] as? String) ?? ""
            let name = (function["name"] as? String) ?? ""
            let arguments: String
            if let string = function["arguments"] as? String {
                arguments = string
            } else if let object = function["arguments"] as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                      let string = String(data: data, encoding: .utf8) {
                // Ollama liefert die Argumente als Objekt statt als String.
                arguments = string
            } else {
                arguments = ""
            }
            return .toolCall(ToolCallInfo(id: id, index: index, name: name, arguments: arguments))
        }
    }

    // MARK: Inline-Think-Tags

    private static let openTags = ["<think>", "<thought>", "<thinking>"]
    private static let closeTags = ["</think>", "</thought>", "</thinking>"]

    private mutating func processContent(_ raw: String) -> [LLMEvent] {
        var events: [LLMEvent] = []
        var text = tagBuffer + raw
        tagBuffer = ""

        while !text.isEmpty {
            let tags = isThinking ? Self.closeTags : Self.openTags
            if let (tagRange, _) = tags.compactMap({ tag in text.range(of: tag).map { ($0, tag) } })
                .min(by: { $0.0.lowerBound < $1.0.lowerBound }) {
                let before = String(text[..<tagRange.lowerBound])
                if !before.isEmpty { events.append(isThinking ? .thinking(before) : .content(before)) }
                isThinking.toggle()
                text = String(text[tagRange.upperBound...])
                continue
            }
            let (safe, partial) = Self.splitPotentialTagEnd(text, tags: tags)
            if !safe.isEmpty { events.append(isThinking ? .thinking(safe) : .content(safe)) }
            tagBuffer = partial
            break
        }
        return events
    }

    /// Trennt ein mögliches, über die Chunk-Grenze verteiltes Tag am Ende ab.
    private static func splitPotentialTagEnd(_ text: String, tags: [String]) -> (safe: String, partial: String) {
        guard let lastAngle = text.lastIndex(of: "<") else { return (text, "") }
        let partial = String(text[lastAngle...])
        guard tags.contains(where: { $0.hasPrefix(partial) }) else { return (text, "") }
        return (String(text[..<lastAngle]), partial)
    }
}
