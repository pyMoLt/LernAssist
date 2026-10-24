import Foundation

/// Baut jeden Chat-Request der App an EINER Stelle: Modellwahl, Sampling-Parameter, Tools,
/// Thinking-Steuerung, Provider-Übersetzung, Header und Timeout. Vorher gab es drei leicht
/// voneinander abweichende Kopien (Chat-Stream, Inline-Erklärung, Hintergrund-Jobs).
nonisolated struct ChatRequestBuilder {

    enum Purpose {
        /// Sichtbare Chat-Antwort: alle Profil-Parameter und Tools.
        case chat
        /// Eigenständige Mini-UI (Inline-Erklärung): Hauptmodell, keine Tools.
        case inline
        /// Hintergrund-Job (Titel, Bildbeschreibung, Quiz, Zusammenfassung).
        case background(useBackgroundModel: Bool, disableThinking: Bool)
    }

    let profile: EndpointProfile

    /// Modell für einen Zweck. Ein leeres Hintergrundmodell bedeutet „Hauptmodell nutzen“ –
    /// dann wird kein zweites Modell geladen.
    func model(for purpose: Purpose) -> String {
        if case .background(let useBackgroundModel, _) = purpose, useBackgroundModel {
            let trimmed = profile.backgroundJobModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return profile.model
    }

    func payload(messages: [[String: Any]], purpose: Purpose, stream: Bool,
                 tools: [[String: Any]] = [], maxTokens: Int? = nil,
                 jsonSchema: (name: String, schema: [String: Any])? = nil) -> [String: Any] {
        var payload: [String: Any] = [
            "model": model(for: purpose),
            "messages": messages,
            "stream": stream,
        ]
        if stream {
            // Ohne dieses Flag liefert kein OpenAI-kompatibler Server das usage-Objekt im
            // letzten Chunk (Tok/s-Metriken). Unbekannte Felder ignorieren alle Server.
            payload["stream_options"] = ["include_usage": true]
        }

        let params = profile.params
        // Einstellungen des Modells (Reiter „Modelle“) haben Vorrang vor dem Profil.
        let modelSettings = ModelSettingsRegistry.shared.settings(for: model(for: purpose))
        if case .chat = purpose {
            if let t = modelSettings.temperature ?? params.temperature { payload["temperature"] = t }
            if let p = modelSettings.topP ?? params.topP { payload["top_p"] = p }
            if let k = modelSettings.topK ?? params.topK { payload["top_k"] = k }
            if let m = modelSettings.maxTokens ?? params.maxTokens { payload["max_tokens"] = m }
            if let mp = modelSettings.minP { payload["min_p"] = mp }
            if let rp = modelSettings.repetitionPenalty { payload["repetition_penalty"] = rp }
            if let pp = modelSettings.presencePenalty ?? params.presencePenalty { payload["presence_penalty"] = pp }
            if let fp = params.frequencyPenalty { payload["frequency_penalty"] = fp }
            if let seed = params.seed { payload["seed"] = seed }
            if let stop = params.stop, !stop.isEmpty { payload["stop"] = stop }
            if !tools.isEmpty {
                payload["tools"] = tools
                payload["tool_choice"] = "auto"
            }
        } else {
            if let t = modelSettings.temperature ?? params.temperature { payload["temperature"] = t }
        }
        if let maxTokens { payload["max_tokens"] = maxTokens }
        if let jsonSchema {
            // Strukturierte Ausgabe (oMLX, LM Studio, OpenAI): erzwingt gültiges JSON statt
            // nachträglicher Reparatur der Modellantwort.
            payload["response_format"] = ["type": "json_schema",
                                          "json_schema": ["name": jsonSchema.name, "strict": true, "schema": jsonSchema.schema]]
        }

        switch purpose {
        case .background(_, let disableThinking):
            if disableThinking { payload = EndpointManager.disableThinkingModifiers(payload) }
        case .chat:
            payload = Self.applyModelSettings(modelSettings, to: payload)
        case .inline:
            // „Text erklären“ ist eine schnelle Nebenfrage: ohne Thinking, damit sofort Text kommt.
            payload = EndpointManager.disableThinkingModifiers(payload)
        }
        return ProviderAdapters.adapter(for: profile.provider).adapt(payload: payload)
    }

    /// Denken, Denkstärke und Schalter der Chat-Vorlage aus den Modell-Einstellungen.
    /// `chat_template_kwargs` werden zusammengeführt (enable_thinking, preserve_thinking,
    /// verification, eigene Schalter); `reasoning_effort` reicht oMLX an die Vorlage weiter.
    static func applyModelSettings(_ settings: ModelSettings, to payload: [String: Any]) -> [String: Any] {
        var p = applyThinking(settings.thinking ?? .serverDefault, budget: settings.thinkingBudget, to: payload)
        if let effort = settings.reasoningEffort, !effort.isEmpty { p["reasoning_effort"] = effort }
        var kwargs = p["chat_template_kwargs"] as? [String: Any] ?? [:]
        if let preserve = settings.preserveThinking { kwargs["preserve_thinking"] = preserve }
        if settings.verification == true { kwargs["verification"] = true }
        for (key, value) in settings.templateKwargs where !key.trimmingCharacters(in: .whitespaces).isEmpty {
            kwargs[key.trimmingCharacters(in: .whitespaces)] = ModelSettings.jsonValue(value)
        }
        if !kwargs.isEmpty { p["chat_template_kwargs"] = kwargs }
        return p
    }

    /// Setzt die Thinking-Steuerung. `chat_template_kwargs.enable_thinking` verstehen oMLX,
    /// LM Studio, llama.cpp und vLLM; `think` ist Ollamas Feld (andere Adapter entfernen es);
    /// `thinking_budget` begrenzt die Denk-Tokens bei oMLX.
    static func applyThinking(_ mode: ThinkingMode, budget: Int?, to payload: [String: Any]) -> [String: Any] {
        var p = payload
        switch mode {
        case .serverDefault:
            break
        case .off:
            p = EndpointManager.disableThinkingModifiers(p)
        case .on:
            p["chat_template_kwargs"] = ["enable_thinking": true]
            p["think"] = true
            if let budget, budget > 0 { p["thinking_budget"] = budget }
        }
        return p
    }

    /// Fertiger URLRequest. Nicht-streamende Requests bekommen den doppelten Leerlauf-Timeout,
    /// weil bis zur fertigen Antwort keine Bytes fließen.
    func urlRequest(payload: [String: Any], stream: Bool) throws -> URLRequest {
        guard let url = EndpointManager.chatCompletionsURL(for: profile) else {
            throw EndpointManager.EndpointError.invalidURL
        }
        let timeout = stream ? profile.effectiveRequestTimeout : profile.effectiveRequestTimeout * 2
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if stream { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        EndpointManager.authHeaders(for: profile).forEach { request.setValue($1, forHTTPHeaderField: $0) }
        // Sortierte Schlüssel: Swift-Dictionaries haben pro Prozessstart eine zufällige Reihenfolge,
        // und die Chat-Vorlage rendert die Tool-Schemas in genau dieser Reihenfolge. Unsortiert
        // war nach jedem App-Neustart der komplette Prefix-Cache des Servers verloren.
        request.httpBody = try Self.serialize(payload)
        return request
    }

    /// Deterministisches JSON für Requests (gleicher Inhalt → gleiche Bytes).
    static func serialize(_ payload: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}
