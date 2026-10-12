import Foundation

/// Streamt Chat-Completions über `URLSession.bytes` und liefert einheitliche `LLMEvent`s.
///
/// Ersetzt den früheren `StreamingDelegate`:
/// - Lesen, Zeilen-Splitten und JSON-Parsen laufen in einem Hintergrund-Task, nicht auf main.
/// - Abbruch = Task canceln (der Consumer bricht die Schleife ab, `onTermination` beendet den
///   Netzwerk-Task) – keine Delegate-Sessions mehr, die invalidiert werden müssen.
/// - Nicht-2xx-Antworten werden mit der Fehlermeldung des Servers gemeldet statt nur mit dem
///   Statuscode (`{"detail": ...}` bei oMLX/FastAPI, `{"error": {...}}` bei OpenAI/LM Studio).
nonisolated enum LLMClient {

    static func stream(_ request: URLRequest, format: StreamWireFormat,
                       session: URLSession = .shared) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        let body = try await readPrefix(of: bytes, limit: 8_192)
                        throw EndpointManager.EndpointError.httpError(http.statusCode,
                                                                      message: serverMessage(fromBody: body))
                    }

                    var parser = StreamEventParser(format: format)
                    var sawDone = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        for event in try parser.consume(line: line) {
                            if event == .done { sawDone = true }
                            continuation.yield(event)
                        }
                        if sawDone { break }
                    }
                    if !sawDone {
                        for event in parser.flush() { continuation.yield(event) }
                        continuation.yield(.done)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Nicht-streamender Request: liefert den Antworttext oder wirft mit Servermeldung.
    static func complete(_ request: URLRequest, session: URLSession = .shared) async throws -> String {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw EndpointManager.EndpointError.httpError(
                http.statusCode, message: serverMessage(fromBody: String(decoding: data.prefix(8_192), as: UTF8.self)))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EndpointManager.EndpointError.parseError
        }
        if let message = StreamEventParser.serverErrorMessage(in: json) {
            throw StreamServerError(message: message)
        }
        guard let content = EndpointManager.extractResponseContent(json) else {
            throw EndpointManager.EndpointError.parseError
        }
        return content
    }

    // MARK: Hilfen

    private static func readPrefix(of bytes: URLSession.AsyncBytes, limit: Int) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Kurze, lesbare Fehlermeldung aus einem Fehler-Body (JSON oder Text).
    static func serverMessage(fromBody body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = StreamEventParser.serverErrorMessage(in: json) {
            return String(message.prefix(400))
        }
        // HTML-Fehlerseiten (Proxies) nicht in die UI kippen.
        if trimmed.hasPrefix("<") { return nil }
        return String(trimmed.prefix(400))
    }
}
