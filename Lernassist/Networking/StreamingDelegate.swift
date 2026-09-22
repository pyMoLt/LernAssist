import Foundation

// MARK: - Chunk-Typen

enum ChunkType {
    case content
    case thinking
    case tool(ToolCallInfo)
}

// MARK: - StreamingDelegate

class StreamingDelegate: NSObject, URLSessionDataDelegate {
    let onChunk: (String, ChunkType) -> Void
    let onFinish: () -> Void
    var onError: ((Error) -> Void)? = nil
    /// Wird aufgerufen wenn ein Chunk Metriken (usage/timings) enthält.
    var onMetrics: ((ChatMetrics) -> Void)? = nil
    /// Ollama /api/chat streamt NDJSON (eine rohe JSON-Zeile pro Chunk, KEIN "data: "-Präfix,
    /// KEIN "[DONE]"-Sentinel – das Ende wird über "done": true IM Chunk selbst signalisiert).
    /// Alle anderen Provider nutzen Standard-SSE ("data: {...}\n\n" + "data: [DONE]").
    private let isNDJSON: Bool

    private var buffer = Data()
    private var isThinking = false
    private var tagBuffer = ""  // Puffer für unvollständige Tags
    private var isFinished = false // Verhindert doppeltes Ausführen von onFinish
    /// Läuft über die gesamte Antwort-Runde mit – siehe MetricsParser.parse(mergingInto:).
    private var accumulatedMetrics = ChatMetrics.empty

    init(onChunk: @escaping (String, ChunkType) -> Void, onFinish: @escaping () -> Void,
         onError: ((Error) -> Void)? = nil, onMetrics: ((ChatMetrics) -> Void)? = nil,
         isNDJSON: Bool = false) {
        self.onChunk = onChunk
        self.onFinish = onFinish
        self.onError = onError
        self.onMetrics = onMetrics
        self.isNDJSON = isNDJSON
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                didReceive response: URLResponse,
                completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // Audit H1: Ohne diese Prüfung lieferte ein 401/500-Endpoint die Anfrage mit
        // HTTP-Fehler-Status, aber OHNE body/didComplete-Error zurück – der Stream "endete
        // erfolgreich" mit leerer Antwort, weder Fehlerkarte noch Fallback griffen. Jetzt wird
        // jeder nicht-2xx-Status explizit als EndpointError an onError gemeldet; die dortige
        // Retry-/Fallback-/Fehler-Logik entscheidet wie bei Verbindungsabbrüchen.
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }
        guard (200...299).contains(http.statusCode) else {
            isFinished = true
            onError?(EndpointManager.EndpointError.httpError(http.statusCode))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Byte-Puffer statt Dekodierung des ganzen Chunks (M1): Ein TCP-Chunk kann
        // mitten in einem UTF-8-Multibyte-Zeichen enden (z.B. Umlaut) — eine frühe
        // Dekodierung des ganzen Chunks liefert nil und verwirft alles. 0x0A kommt
        // in Multibyte-Sequenzen nie vor, daher ist die Zeilen-Trennung auf
        // Byte-Ebene verlustfrei; dekodiert wird erst die vollständige Zeile.
        buffer += data

        // Zeilen verarbeiten
        while let lineEnd = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<lineEnd)
            buffer.removeSubrange(buffer.startIndex...lineEnd)
            guard let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !line.isEmpty else { continue }

            if isNDJSON {
                // Ollama: jede Zeile ist bereits ein rohes JSON-Objekt ohne "data: "-Präfix.
                processDelta(line)
                continue
            }

            // SSE erlaubt "data:" mit oder ohne Leerzeichen vor der Payload.
            guard line.hasPrefix("data:") else { continue }
            var jsonStr = String(line.dropFirst(5))
            if jsonStr.hasPrefix(" ") { jsonStr.removeFirst() }
            if jsonStr == "[DONE]" {
                if !isFinished {
                    isFinished = true
                    flush()
                    onFinish()
                }
                return
            }

            processDelta(jsonStr)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !isFinished {
            isFinished = true
            flush()
            if let error = error {
                onError?(error)
            } else {
                onFinish()
            }
        }
    }

    /// Ausstehenden tagBuffer leeren – wichtig wenn Modell </think> nie schickt
    private func flush() {
        if !tagBuffer.isEmpty {
            // Unvollständiges Tag-Fragment als Content ausgeben
            onChunk(tagBuffer, isThinking ? .thinking : .content)
            tagBuffer = ""
        }
        // isThinking reset: Falls Modell </think> nie gesendet hat, alle zukünftigen Chunks als .content
        isThinking = false
    }

    // MARK: - Delta verarbeiten

    private func processDelta(_ jsonStr: String) {
        guard
            let data = jsonStr.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        // Metriken (usage/timings) ZUERST und UNABHÄNGIG vom choices/delta-Aufbau auswerten.
        // Wichtig: der finale Chunk, der bei aktivem `stream_options.include_usage` das
        // usage-Objekt trägt, hat laut OpenAI-Spec ein LEERES "choices": [] – ein Guard, der
        // zwingend choices.first?["delta"] verlangt (wie zuvor hier), würde diesen Chunk komplett
        // verwerfen, BEVOR die Metriken je ausgelesen werden. Genau das verhinderte bisher jede
        // Tok/s-Anzeige, selbst mit korrekt gesetztem include_usage-Flag.
        //
        // mergingInto: einige Server (llama.cpp) schicken `timings` in JEDEM Zwischen-Chunk, aber
        // `usage` nur im letzten – ohne Merge würde ein reiner Timing-Zwischenstand die schon
        // bekannten Token-Zahlen auf 0 zurücksetzen (Flackern in der MetricsBar).
        if let metrics = MetricsParser.parse(fromDict: json, mergingInto: accumulatedMetrics) {
            accumulatedMetrics = metrics
            onMetrics?(metrics)
        }

        // OpenAI-Format (LM Studio, OpenAI, Groq, Together, llama.cpp, MLX): choices[0].delta
        if let choices = json["choices"] as? [[String: Any]],
           let delta = choices.first?["delta"] as? [String: Any] {
            extractToolCalls(from: delta["tool_calls"] as? [[String: Any]])

            // Thinking (manche Modelle nutzen separates "thinking", "reasoning_content" oder "reasoning" Feld)
            if let thinkingText = delta["thinking"] as? String ?? delta["reasoning_content"] as? String ?? delta["reasoning"] as? String, !thinkingText.isEmpty {
                onChunk(thinkingText, .thinking)
            }

            // Content verarbeiten (inkl. <think>-Tag-Erkennung)
            if let content = delta["content"] as? String, !content.isEmpty {
                processContent(content)
            }
            return
        }

        // Ollama-Format (/api/chat, NDJSON): top-level "message": { role, content, thinking, tool_calls }
        if let message = json["message"] as? [String: Any] {
            extractToolCalls(from: message["tool_calls"] as? [[String: Any]])
            // Audit M5: Der OpenAI-Zweig liest "thinking"/"reasoning*", der Ollama-Zweig tat das
            // nicht – der Denkprozess von think-Modellen ging still verloren, obwohl adaptPayload
            // aktiv think-Payloads erzeugt.
            if let thinkingText = message["thinking"] as? String ?? message["reasoning_content"] as? String ?? message["reasoning"] as? String, !thinkingText.isEmpty {
                onChunk(thinkingText, .thinking)
            }
            if let content = message["content"] as? String, !content.isEmpty {
                processContent(content)
            }
        }
    }

    /// Extrahiert Tool-Calls aus OpenAI- (`delta.tool_calls`) oder Ollama-Deltas (`message.tool_calls`).
    /// Ollama sendet meist den kompletten Call in einem Chunk statt inkrementeller Argument-Fragmente,
    /// aber die Struktur (`function.name`/`function.arguments`) ist identisch zu OpenAI.
    private func extractToolCalls(from tools: [[String: Any]]?) {
        guard let tools else { return }
        for tool in tools {
            let function_ = tool["function"] as? [String: Any] ?? [:]
            // OpenAI liefert `index` auf Call-Ebene, Ollamas natives Streaming-Format kann
            // ihn im Function-Objekt liefern. Der Index hält parallele Calls ohne ID getrennt.
            let index     = (tool["index"] as? Int) ?? (function_["index"] as? Int)
            let toolId    = (tool["id"] as? String) ?? ""
            let name      = (function_["name"] as? String) ?? ""
            let argsRaw   = function_["arguments"]
            let args: String
            if let argsStr = argsRaw as? String {
                args = argsStr
            } else if let argsDict = argsRaw as? [String: Any],
                      let argsData = try? JSONSerialization.data(withJSONObject: argsDict),
                      let argsStr = String(data: argsData, encoding: .utf8) {
                // Ollama liefert arguments teils als verschachteltes JSON-Objekt statt als String.
                args = argsStr
            } else {
                args = ""
            }
            let info = ToolCallInfo(id: toolId, index: index, name: name, arguments: args)
            onChunk("", .tool(info))
        }
    }

    // MARK: - Content mit Think-Tag-Erkennung
    //
    // Parst korrekt auch wenn:
    // - Tags mitten in einem Chunk liegen (Text vor UND nach dem Tag)
    // - Tags über Chunk-Grenzen aufgeteilt sind (tagBuffer)

    private func processContent(_ raw: String) {
        // Tagpuffer voranstellen (für über Chunks aufgeteilte Tags)
        var text = tagBuffer + raw
        tagBuffer = ""

        while !text.isEmpty {
            if isThinking {
                // Suche nach End-Tags: </think>, </thought>, </thinking>
                let closingTags = ["</think>", "</thought>", "</thinking>"]
                var foundMatch = false
                
                for tag in closingTags {
                    if let range = text.range(of: tag) {
                        let before = String(text[text.startIndex..<range.lowerBound])
                        if !before.isEmpty { onChunk(before, .thinking) }
                        isThinking = false
                        text = String(text[range.upperBound...])
                        foundMatch = true
                        break
                    }
                }
                
                if foundMatch { continue }

                if mightEndWithPartialTag(text, tags: closingTags + ["</thi", "</tho", "</t"]) {
                    let (safe, partial) = splitAtPotentialTagEnd(text, tags: closingTags)
                    if !safe.isEmpty { onChunk(safe, .thinking) }
                    tagBuffer = partial
                    return
                } else {
                    onChunk(text, .thinking)
                    return
                }
            } else {
                // Suche nach Start-Tags: <think>, <thought>, <thinking>
                let startTags = ["<think>", "<thought>", "<thinking>"]
                var foundMatch = false
                
                for tag in startTags {
                    if let range = text.range(of: tag) {
                        let before = String(text[text.startIndex..<range.lowerBound])
                        if !before.isEmpty { onChunk(before, .content) }
                        isThinking = true
                        text = String(text[range.upperBound...])
                        foundMatch = true
                        break
                    }
                }
                
                if foundMatch { continue }

                if mightEndWithPartialTag(text, tags: startTags + ["<thi", "<tho", "<t"]) {
                    let (safe, partial) = splitAtPotentialTagEnd(text, tags: startTags)
                    if !safe.isEmpty { onChunk(safe, .content) }
                    tagBuffer = partial
                    return
                } else {
                    onChunk(text, .content)
                    return
                }
            }
        }
    }

    /// Prüft ob text mit einem Anfang eines der Tags endet
    private func mightEndWithPartialTag(_ text: String, tags: [String]) -> Bool {
        for tag in tags {
            if text.hasSuffix(tag) { return true }
        }
        // Auch prüfen ob letztes Zeichen "<" oder "</" ist
        if text.hasSuffix("<") || text.hasSuffix("</") { return true }
        return false
    }

    /// Trennt sicheren Content von potenziellem Teil-Tag am Ende
    private func splitAtPotentialTagEnd(_ text: String, tags: [String]) -> (safe: String, partial: String) {
        // Finde das letzte "<" und prüfe ob der Rest ein Tag-Anfang sein könnte
        guard let lastAngle = text.lastIndex(of: "<") else {
            return (text, "")
        }
        let partial = String(text[lastAngle...])
        let safe = String(text[text.startIndex..<lastAngle])

        // Ist der Partial ein möglicher Anfang eines der gesuchten Tags?
        for tag in tags {
            if tag.hasPrefix(partial) {
                return (safe, partial)
            }
        }
        return (text, "")
    }
}
