import Foundation

// MARK: - Provider-Adapter

/// Kapselt ALLE anbieterspezifischen Unterschiede (URLs, Payload-Format, Bildformat, Modellliste,
/// Stream-Format). Der Rest der App baut Nachrichten einheitlich im OpenAI-Format; erst direkt
/// vor dem Senden übersetzt der Adapter.
///
/// Einen neuen Anbieter hinzufügen = einen Adapter schreiben und in `ProviderAdapters.adapter(for:)`
/// eintragen. Keine `switch provider`-Stellen mehr quer durch ChatViewModel/EndpointManager.
nonisolated protocol ProviderAdapter: Sendable {
    var wireFormat: StreamWireFormat { get }
    func chatURL(base: String) -> URL?
    func modelsURL(base: String) -> URL?
    /// Übersetzt einen Payload im internen OpenAI-Format in das Anbieterformat.
    func adapt(payload: [String: Any]) -> [String: Any]
    /// Liest die Modellliste aus der Antwort von `modelsURL`.
    func parseModels(_ json: [String: Any]) -> [ProviderModel]
}

/// Ein vom Server gemeldetes Modell.
nonisolated struct ProviderModel: Equatable, Sendable {
    let id: String
    var contextWindow: Int?
    var supportsVision: Bool?
    var isLoaded: Bool?
}

nonisolated enum ProviderAdapters {
    static func adapter(for provider: EndpointProvider) -> ProviderAdapter {
        switch provider {
        case .openAICompatible, .mlx: return OpenAICompatibleAdapter()
        case .lmStudioNative:         return LMStudioNativeAdapter()
        case .ollama:                 return OllamaAdapter()
        case .omlx:                   return OMLXAdapter()
        }
    }
}

// MARK: - OpenAI-kompatibel (OpenAI, Groq, Together, llama.cpp, MLX, LM Studio /v1)

nonisolated struct OpenAICompatibleAdapter: ProviderAdapter {
    var wireFormat: StreamWireFormat { .sse }
    func chatURL(base: String) -> URL? { URL(string: base + "/v1/chat/completions") }
    func modelsURL(base: String) -> URL? { URL(string: base + "/v1/models") }
    func adapt(payload: [String: Any]) -> [String: Any] {
        // `think` ist Ollamas Feld; strikte OpenAI-Endpunkte lehnen unbekannte Felder teils ab.
        var p = payload
        p.removeValue(forKey: "think")
        p.removeValue(forKey: "thinking_budget")
        return p
    }

    func parseModels(_ json: [String: Any]) -> [ProviderModel] {
        guard let list = json["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return ProviderModel(id: id, contextWindow: Self.contextWindow(in: item))
        }.sorted { $0.id < $1.id }
    }

    /// Kontextfenster unter allen bekannten Feldnamen (oMLX/vLLM: `max_model_len`).
    static func contextWindow(in item: [String: Any]) -> Int? {
        for key in ["context_window", "context_length", "max_context_length",
                    "loaded_context_length", "max_model_len", "max_context_window"] {
            if let value = item[key] as? Int, value > 0 { return value }
        }
        return nil
    }
}

// MARK: - oMLX

/// oMLX spricht OpenAI-kompatibel. Unterschiede: Kontextfenster heißt `max_model_len`,
/// Thinking nur über `chat_template_kwargs` (ein zusätzliches Top-Level-Feld kann mit 422
/// kollidieren), Fehler im FastAPI-Format `{"detail": …}` (liest LLMClient).
nonisolated struct OMLXAdapter: ProviderAdapter {
    var wireFormat: StreamWireFormat { .sse }
    func chatURL(base: String) -> URL? { URL(string: base + "/v1/chat/completions") }
    func modelsURL(base: String) -> URL? { URL(string: base + "/v1/models") }
    func statusURL(base: String) -> URL? { URL(string: base + "/v1/models/status") }
    func healthURL(base: String) -> URL? { URL(string: base + "/health") }
    func rerankURL(base: String) -> URL? { URL(string: base + "/v1/rerank") }

    func loadURL(base: String, model: String) -> URL? {
        guard let encoded = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) else { return nil }
        return URL(string: base + "/v1/models/\(encoded)/load")
    }

    func adapt(payload: [String: Any]) -> [String: Any] {
        var p = payload
        p.removeValue(forKey: "think")
        p.removeValue(forKey: "enable_thinking")
        if p["thinking_budget"] != nil,
           let kwargs = p["chat_template_kwargs"] as? [String: Any],
           kwargs["enable_thinking"] as? Bool == false {
            p.removeValue(forKey: "thinking_budget")
        }
        return p
    }

    func parseModels(_ json: [String: Any]) -> [ProviderModel] { OpenAICompatibleAdapter().parseModels(json) }

    /// Liest `/v1/models/status`: Typ (vlm = Vision), Ladezustand, maximales Kontextfenster.
    func parseStatus(_ json: [String: Any]) -> [ProviderModel] {
        let list = (json["models"] as? [[String: Any]]) ?? (json["data"] as? [[String: Any]]) ?? []
        return list.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let type = (item["model_type"] as? String)?.lowercased()
            return ProviderModel(id: id,
                                 contextWindow: (item["max_context_window"] as? Int) ?? OpenAICompatibleAdapter.contextWindow(in: item),
                                 supportsVision: type.map { $0 == "vlm" },
                                 isLoaded: item["loaded"] as? Bool)
        }.sorted { $0.id < $1.id }
    }
}

// MARK: - LM Studio nativ (/api/v0)

nonisolated struct LMStudioNativeAdapter: ProviderAdapter {
    var wireFormat: StreamWireFormat { .sse }
    func chatURL(base: String) -> URL? { URL(string: base + "/api/v0/chat/completions") }
    func modelsURL(base: String) -> URL? { URL(string: base + "/v1/models") }
    func adapt(payload: [String: Any]) -> [String: Any] { payload }
    func parseModels(_ json: [String: Any]) -> [ProviderModel] { OpenAICompatibleAdapter().parseModels(json) }
}

// MARK: - Ollama (/api/chat)

nonisolated struct OllamaAdapter: ProviderAdapter {
    var wireFormat: StreamWireFormat { .ndjson }
    func chatURL(base: String) -> URL? { URL(string: base + "/api/chat") }
    func modelsURL(base: String) -> URL? { URL(string: base + "/api/tags") }

    func adapt(payload: [String: Any]) -> [String: Any] {
        var p = payload
        // Ollama /api/chat kennt stream_options nicht.
        p.removeValue(forKey: "stream_options")
        if let messages = p["messages"] as? [[String: Any]] {
            p["messages"] = Self.ollamaMessages(from: messages)
        }
        return p
    }

    func parseModels(_ json: [String: Any]) -> [ProviderModel] {
        guard let list = json["models"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            return ProviderModel(id: name)
        }.sorted { $0.id < $1.id }
    }

    /// Übersetzt die intern einheitliche OpenAI-Historie ins native Ollama-Format:
    /// - Bilder: `content`-Teile mit `image_url` → flaches `images: [base64]`-Feld
    ///   (dadurch funktioniert auch ein Fallback von einem OpenAI-Profil auf Ollama).
    /// - Tool-Ergebnisse: `tool_name` statt `tool_call_id`, Argumente als Objekt.
    static func ollamaMessages(from messages: [[String: Any]]) -> [[String: Any]] {
        var pendingToolNames: [String] = []
        var nextToolNameIndex = 0

        return messages.map { message in
            var converted = message
            let role = converted["role"] as? String

            if let parts = converted["content"] as? [[String: Any]] {
                let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
                let images = parts.compactMap { part -> String? in
                    guard let url = (part["image_url"] as? [String: Any])?["url"] as? String,
                          let comma = url.firstIndex(of: ",") else { return nil }
                    return String(url[url.index(after: comma)...])
                }
                converted["content"] = text.isEmpty ? " " : text
                if !images.isEmpty { converted["images"] = images }
            }

            if role == "assistant", let calls = converted["tool_calls"] as? [[String: Any]] {
                pendingToolNames = calls.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
                nextToolNameIndex = 0
                converted["tool_calls"] = calls.enumerated().map { index, call in
                    let function = call["function"] as? [String: Any] ?? [:]
                    return [
                        "type": "function",
                        "function": [
                            "index": index,
                            "name": function["name"] as? String ?? "",
                            "arguments": arguments(from: function["arguments"])
                        ] as [String: Any]
                    ]
                }
                if !(converted["content"] is String) { converted["content"] = "" }
            } else if role == "tool" {
                if nextToolNameIndex < pendingToolNames.count {
                    converted["tool_name"] = pendingToolNames[nextToolNameIndex]
                    nextToolNameIndex += 1
                }
                converted.removeValue(forKey: "tool_call_id")
                if !(converted["content"] is String) { converted["content"] = "" }
            }
            return converted
        }
    }

    private static func arguments(from raw: Any?) -> [String: Any] {
        if let object = raw as? [String: Any] { return object }
        guard let string = raw as? String,
              let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }
}
