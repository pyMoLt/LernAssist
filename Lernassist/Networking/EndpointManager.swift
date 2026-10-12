import Foundation

/// Zustandslose Netzwerk-Helfer: URL-Normalisierung, adaptive Endpunkte je Provider,
/// Auth-Header, Modell-Liste und Verbindungs-Fehlererkennung.
nonisolated enum EndpointManager {

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
        ProviderAdapters.adapter(for: profile.provider).chatURL(base: normalizedBase(profile.baseURL))
    }

    // MARK: - Models-URL

    /// Gibt die Modell-Listen-URL für den angegebenen Provider zurück.
    static func modelsURL(for profile: EndpointProfile) -> URL? {
        ProviderAdapters.adapter(for: profile.provider).modelsURL(base: normalizedBase(profile.baseURL))
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
        ProviderAdapters.adapter(for: profile.provider).adapt(payload: payload)
    }

    /// Weiterleitung für bestehende Aufrufer/Tests (Implementierung im OllamaAdapter).
    static func ollamaMessages(from messages: [[String: Any]]) -> [[String: Any]] {
        OllamaAdapter.ollamaMessages(from: messages)
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
    /// Intern immer im OpenAI-Format – die Übersetzung für Ollama übernimmt `OllamaAdapter`
    /// beim Senden. Dadurch passt der Payload auch nach einem Fallback auf einen anderen Anbieter.
    static func userImageMessage(text: String, base64: String, provider: EndpointProvider) -> [String: Any] {
        let safeText = text.isEmpty ? " " : text
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
        try await fetchProviderModels(for: profile).map { (id: $0.id, contextWindow: $0.contextWindow) }
    }

    static func fetchProviderModels(for profile: EndpointProfile) async throws -> [ProviderModel] {
        guard let url = modelsURL(for: profile) else {
            throw EndpointError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: profile.isRemote ? 15 : 8)
        authHeaders(for: profile).forEach { request.setValue($1, forHTTPHeaderField: $0) }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw EndpointError.httpError(http.statusCode,
                                          message: LLMClient.serverMessage(fromBody: String(decoding: data.prefix(4_096), as: UTF8.self)))
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw EndpointError.parseError }
        let models = ProviderAdapters.adapter(for: profile.provider).parseModels(json)
        guard !models.isEmpty || json["data"] != nil || json["models"] != nil else { throw EndpointError.parseError }
        return models
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
        if case EndpointError.httpError(let code, _) = error {
            return [401, 403, 404, 408, 429, 500, 502, 503, 504, 529].contains(code)
        }
        return false
    }

    enum EndpointError: LocalizedError {
        case invalidURL
        /// HTTP-Status plus (falls vorhanden) die Fehlermeldung des Servers.
        case httpError(Int, message: String?)
        case parseError

        var errorDescription: String? {
            switch self {
            case .invalidURL:       return "Ungültige Endpunkt-URL"
            case .httpError(let c, let message):
                if let message, !message.isEmpty { return "HTTP-Fehler \(c): \(message)" }
                return "HTTP-Fehler \(c)"
            case .parseError:       return "Antwort konnte nicht verarbeitet werden"
            }
        }
    }
}
