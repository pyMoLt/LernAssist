import Foundation

/// Zustandslose Netzwerk-Helfer: URL-Normalisierung, adaptive Endpunkte je Provider,
/// Auth-Header, Modell-Liste und Verbindungs-Fehlererkennung.
enum EndpointManager {

    // MARK: - URL-Normalisierung

    /// Bereinigt eine Basis-URL: entfernt Trailing-Slashes sowie bekannte Endpunkt-Suffixe
    /// (/v1, /api/v0, /chat/completions, ...), sodass immer der reine Host übrig bleibt.
    /// Unterstützt: LM Studio, Ollama, llama.cpp, OpenAI, Groq, Together AI etc.
    static func normalizedBase(_ raw: String) -> String {
        var u = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u = String(u.dropLast()) }

        // Längste Suffixe zuerst; wird ITERATIV gestrippt. Der frühere einzelne Durchlauf mit
        // `break` ließ zusammengesetzte Suffixe unaufgeräumt: ".../openai/v1/chat/completions"
        // matchte zuerst den kurzen "/v1/chat/completions"-Eintrag, der dann erst später in der
        // Liste stand als der lange.
        let suffixesToStrip = [
            "/api/v0/chat/completions",
            "/api/v1/chat/completions",
            "/openai/v1/chat/completions",
            "/v1/chat/completions",
            "/v1/messages",
            "/api/v0/models",
            "/api/v1/models",
            "/openai/v1/models",
            "/v1/models",
            "/api/chat",
            "/api/generate",
            "/api/tags",
            "/api/v0",
            "/api/v1",
            "/openai/v1",
            "/v1"
        ]

        var strippedAgain = true
        while strippedAgain {
            strippedAgain = false
            for suffix in suffixesToStrip {
                if u.lowercased().hasSuffix(suffix.lowercased()) {
                    u = String(u.dropLast(suffix.count))
                    while u.hasSuffix("/") { u = String(u.dropLast()) }
                    strippedAgain = true
                    break
                }
            }
        }
        return u
    }

    // MARK: - Chat-Completions-URL

    /// Gibt die passende Chat-Completions-URL für den angegebenen Provider zurück.
    static func chatCompletionsURL(for profile: EndpointProfile) -> URL? {
        let base = normalizedBase(profile.baseURL)
        switch profile.provider {
        case .openAICompatible, .mlx:
            return URL(string: base + "/v1/chat/completions")
        case .lmStudioNative:
            return URL(string: base + "/api/v0/chat/completions")
        case .ollama:
            return URL(string: base + "/api/chat")
        }
    }

    // MARK: - Models-URL

    /// Gibt die Modell-Listen-URL für den angegebenen Provider zurück.
    static func modelsURL(for profile: EndpointProfile) -> URL? {
        let base = normalizedBase(profile.baseURL)
        switch profile.provider {
        case .openAICompatible, .lmStudioNative, .mlx:
            return URL(string: base + "/v1/models")
        case .ollama:
            return URL(string: base + "/api/tags")
        }
    }

    // MARK: - Auth-Header

    /// Gibt die korrekten Auth-Header je Provider zurück.
    static func authHeaders(for profile: EndpointProfile) -> [String: String] {
        guard !profile.apiKey.isEmpty else { return [:] }
        return ["Authorization": "Bearer \(profile.apiKey)"]
    }

    // MARK: - Payload-Anpassung je Provider

    /// Passt den Streaming-Payload an das Provider-Format an.
    /// Hauptanpassungen: Ollama braucht kein stream_options, Ollama /api/chat hat Sonderformat.
    static func adaptPayload(_ payload: [String: Any], for profile: EndpointProfile) -> [String: Any] {
        var p = payload
        switch profile.provider {
        case .ollama:
            // Ollama /api/chat kennt stream_options nicht → entfernen
            p.removeValue(forKey: "stream_options")
            if let messages = p["messages"] as? [[String: Any]] {
                // Die native Ollama-API verwendet für Tool-Ergebnisse `tool_name` statt
                // OpenAIs `tool_call_id` und erwartet die Argumente als Objekt. Ohne diese
                // Übersetzung konnte ein nativer Ollama-Agent nach einem Tool-Call vorzeitig
                // abbrechen oder den Folge-Turn ablehnen.
                p["messages"] = ollamaMessages(from: messages)
            }
        default:
            break
        }
        return p
    }

    /// Wandelt die einheitlich intern gespeicherte OpenAI-Tool-Historie in das native
    /// `/api/chat`-Format von Ollama um. Mehrere Tool-Ergebnisse werden positionsgetreu mit
    /// dem zugehörigen Funktionsnamen verknüpft, wie es Ollamas Agent-Loop verlangt.
    static func ollamaMessages(from messages: [[String: Any]]) -> [[String: Any]] {
        var pendingToolNames: [String] = []
        var nextToolNameIndex = 0

        return messages.map { message in
            var converted = message
            let role = converted["role"] as? String

            if role == "assistant", let calls = converted["tool_calls"] as? [[String: Any]] {
                pendingToolNames = calls.compactMap { call in
                    (call["function"] as? [String: Any])?["name"] as? String
                }
                nextToolNameIndex = 0

                converted["tool_calls"] = calls.enumerated().map { index, call in
                    let function = call["function"] as? [String: Any] ?? [:]
                    let arguments = ollamaArguments(from: function["arguments"])
                    return [
                        "type": "function",
                        "function": [
                            "index": index,
                            "name": function["name"] as? String ?? "",
                            "arguments": arguments
                        ] as [String: Any]
                    ]
                }

                // OpenAI erlaubt bei Tool-Calls null; Ollama erwartet einen String bzw. ein
                // ausgelassenes Feld. Ein leerer String ist für die gestreamte Antwort stabil.
                if !(converted["content"] is String) {
                    converted["content"] = ""
                }
            } else if role == "tool" {
                if nextToolNameIndex < pendingToolNames.count {
                    converted["tool_name"] = pendingToolNames[nextToolNameIndex]
                    nextToolNameIndex += 1
                }
                converted.removeValue(forKey: "tool_call_id")
                if !(converted["content"] is String) {
                    converted["content"] = ""
                }
            }
            return converted
        }
    }

    private static func ollamaArguments(from raw: Any?) -> [String: Any] {
        if let object = raw as? [String: Any] { return object }
        guard let string = raw as? String,
              let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    // MARK: - "No Thinking" für Hintergrund-Jobs (Best-effort)

    /// Setzt gleichzeitig alle bekannten Mechanismen, um Reasoning-Modelle (Qwen3-Familie u.a.)
    /// zu einer direkten Antwort ohne sichtbaren Denkprozess zu bewegen. Welcher Mechanismus
    /// tatsächlich greift, hängt vom Server/der Modellversion ab – nicht erkannte Felder werden
    /// von allen getesteten Backends ignoriert, daher ist das gleichzeitige Setzen unkritisch:
    /// - `chat_template_kwargs.enable_thinking = false`: von llama.cpp/LM Studio/vLLM/SGLang
    ///   ausgewertet (Qwen3.5/3.6), aber je nach llama.cpp-Version inkonsistent unterstützt.
    /// - `think = false`: Ollamas natives Feld, funktioniert zuverlässig für viele
    ///   Reasoning-Modellfamilien (Qwen3, DeepSeek-R1, ...).
    /// - Das `/no_think`-Textfragment für ältere Qwen3-Modelle (vor 3.5) wird NICHT hier gesetzt,
    ///   da es an den Prompt-Text selbst angehängt werden muss – siehe ChatViewModel.
    static func disableThinkingModifiers(_ payload: [String: Any]) -> [String: Any] {
        var p = payload
        p["chat_template_kwargs"] = ["enable_thinking": false]
        p["think"] = false
        return p
    }

    // MARK: - Provider-spezifische Nachrichten-Formate

    /// Baut eine User-Nachricht mit Bildanhang im jeweiligen Provider-Format.
    /// OpenAI-kompatibel: `content` wird ein Array aus Text-/Image-Teilen.
    /// Ollama `/api/chat`: `content` bleibt ein einfacher String, das Bild wandert in ein
    /// separates `images: [base64]`-Feld auf der Nachricht (Ollama kennt kein `image_url`).
    static func userImageMessage(text: String, base64: String, provider: EndpointProvider) -> [String: Any] {
        let safeText = text.isEmpty ? " " : text
        if provider == .ollama {
            return ["role": "user", "content": safeText, "images": [base64]]
        }
        return ["role": "user", "content": [
            ["type": "text", "text": safeText],
            ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(base64)"]]
        ]]
    }

    /// Extrahiert den Antwort-Text einer NICHT-gestreamten Chat-Completion-Response.
    /// Unterstützt OpenAI-Format (`choices[0].message.content`) und Ollama (`message.content`).
    static func extractResponseContent(_ json: [String: Any]) -> String? {
        if let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        if let message = json["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        return nil
    }

    // MARK: - Modell-Liste abrufen

    /// Fragt die Modell-Liste inkl. Kontextfenster-Größe ab.
    static func fetchModels(for profile: EndpointProfile) async throws -> [(id: String, contextWindow: Int?)] {
        guard let url = modelsURL(for: profile) else {
            throw EndpointError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: 8)
        authHeaders(for: profile).forEach { request.setValue($1, forHTTPHeaderField: $0) }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw EndpointError.httpError(http.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw EndpointError.parseError }

        // OpenAI-Format: { "data": [ { "id": "...", "context_window": 8192, ... } ] }
        if let list = json["data"] as? [[String: Any]] {
            return list.compactMap { item -> (id: String, contextWindow: Int?)? in
                guard let id = item["id"] as? String else { return nil }
                let ctx = (item["context_window"] as? Int)
                    ?? (item["context_length"] as? Int)
                    ?? (item["max_context_length"] as? Int)
                    ?? (item["loaded_context_length"] as? Int)
                return (id: id, contextWindow: ctx)
            }.sorted(by: { $0.id < $1.id })
        }

        // Ollama /api/tags Format: { "models": [ { "name": "llama3.2:latest", ... } ] }
        if let list = json["models"] as? [[String: Any]] {
            return list.compactMap { item -> (id: String, contextWindow: Int?)? in
                guard let name = item["name"] as? String else { return nil }
                return (id: name, contextWindow: nil)
            }.sorted(by: { $0.id < $1.id })
        }

        throw EndpointError.parseError
    }

    // MARK: - Verbindungs-Fehler-Erkennung

    /// True wenn der Fehler auf einen nicht erreichbaren Server hindeutet.
    static func isConnectivityError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
             .notConnectedToInternet, .timedOut, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    /// True, wenn der Fehler eine automatische Wiederholung über das Fallback-Profil rechtfertigt:
    /// echte Verbindungsfehler ODER eindeutig endpunktbezogene HTTP-Fehler (Auth/Endpoint/Server).
    /// 400 bleibt bewusst außen vor – das ist ein Payload-Problem, das das Fallback-Profil
    /// genauso trifft, und würde nur einen sinnlosen zweiten Request kosten.
    static func shouldAttemptFallback(error: Error) -> Bool {
        if isConnectivityError(error) { return true }
        if case EndpointError.httpError(let code) = error {
            return [401, 403, 404, 408, 429, 500, 502, 503, 504, 529].contains(code)
        }
        return false
    }

    enum EndpointError: LocalizedError {
        case invalidURL
        case httpError(Int)
        case parseError

        var errorDescription: String? {
            switch self {
            case .invalidURL:       return "Ungültige Endpunkt-URL"
            case .httpError(let c): return "HTTP-Fehler \(c)"
            case .parseError:       return "Antwort konnte nicht verarbeitet werden"
            }
        }
    }
}
