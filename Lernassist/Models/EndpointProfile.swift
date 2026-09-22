import Foundation

// MARK: - EndpointProvider

/// Art des Backend-Servers — bestimmt URL-Schema, Auth-Header und Streaming-Format.
enum EndpointProvider: String, Codable, CaseIterable {
    case openAICompatible = "openai_compat"   // OpenAI, Groq, Together, LM Studio /v1, llama.cpp
    case lmStudioNative   = "lmstudio_native" // LM Studio /api/v0 — echte server-seitige Tok/s
    case ollama           = "ollama"          // Ollama /api/chat — echte Tok/s via eval_count/eval_duration
    case mlx              = "mlx"             // Apple MLX Server (OpenAI-kompatibel, localhost:8080)

    var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI-kompatibel"
        case .lmStudioNative:   return "LM Studio Native (/api/v0)"
        case .ollama:           return "Ollama (/api/chat)"
        case .mlx:              return "MLX (Apple Silicon)"
        }
    }

    var shortLabel: String {
        switch self {
        case .openAICompatible: return "OpenAI-compat"
        case .lmStudioNative:   return "LM Studio"
        case .ollama:           return "Ollama"
        case .mlx:              return "MLX"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAICompatible: return "http://localhost:1234"
        case .lmStudioNative:   return "http://localhost:1234"
        case .ollama:           return "http://localhost:11434"
        case .mlx:              return "http://localhost:8080"
        }
    }

    var apiKeyLabel: String {
        switch self {
        case .openAICompatible: return "API Key (sk-... leer lassen für lokal)"
        case .lmStudioNative:   return "API Key (optional)"
        case .ollama:           return "API Key (optional, Standard: leer)"
        case .mlx:              return "API Key (optional)"
        }
    }

    var systemImage: String {
        switch self {
        case .openAICompatible: return "cloud"
        case .lmStudioNative:   return "gauge.high"
        case .ollama:           return "hare.fill"
        case .mlx:              return "apple.logo"
        }
    }

    var helpText: String {
        switch self {
        case .openAICompatible:
            return """
            **OpenAI-kompatibles Format** (POST /v1/chat/completions)

            Kompatibel mit:
            • OpenAI (api.openai.com)
            • Groq (api.groq.com/openai/v1)
            • Together AI (api.together.ai/v1)
            • LM Studio /v1-Route
            • llama.cpp-Server
            • LocalAI, Mistral API u.v.m.

            Auth: Authorization: Bearer <api-key>
            Metriken: Token-Counts im letzten Chunk mit stream_options.include_usage=true.
            Groq liefert zusätzlich completion_time für exakte Tok/s-Berechnung.
            TPS wird für andere Provider clientseitig berechnet.
            """
        case .lmStudioNative:
            return """
            **LM Studio Native API** (POST /api/v0/chat/completions)

            Liefert echte, server-seitige Metriken im stats-Objekt:
            • tokens_per_second (exakt, server-gemessen)
            • time_to_first_token (TTFT)

            Nur bei LM Studio aktivieren!
            Bei llama.cpp, Ollama oder OpenAI existiert /api/v0/ NICHT.

            Auth: Authorization: Bearer <key> (optional)
            Metriken: stats.tokens_per_second im letzten Chunk.
            """
        case .ollama:
            return """
            **Ollama Native API** (POST /api/chat)

            Format: NDJSON (Newline-Delimited JSON)
            Kein "data:"-Prefix wie bei SSE.

            Liefert echte Timing-Daten im letzten Chunk (done: true):
            • eval_count (Output-Tokens)
            • eval_duration (Nanosekunden)
            → TPS = eval_count / eval_duration × 10⁹

            Auth: Keine Authentication nötig (Standard).
            Modell-Liste: GET /api/tags
            """
        case .mlx:
            return """
            **MLX LM Server** (POST /v1/chat/completions)

            OpenAI-kompatible API für Modelle, die mit
            mlx-lm auf Apple Silicon ausgeführt werden.
            Standard-Port: 8080.

            Format: Standard OpenAI SSE.
            Auth: Keine Authentication nötig.
            Metriken: Standard OpenAI usage-Objekt.
            TPS wird clientseitig berechnet.
            """
        }
    }
}

// MARK: - ModelParams

/// Generierungs-Parameter für OpenAI-kompatible Endpunkte. Alle Felder optional —
/// nur gesetzte Werte werden gesendet, damit der Server bei nil seine Defaults verwendet.
struct ModelParams: Codable, Equatable {
    var temperature: Double?
    var topP: Double?
    var topK: Int?
    var maxTokens: Int?
    var presencePenalty: Double?
    var frequencyPenalty: Double?
    var seed: Int?
    var stop: [String]?

    static let empty = ModelParams()
}

// MARK: - EndpointProfile

/// Ein konfigurierbares Backend-Endpunkt-Profil.
struct EndpointProfile: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var baseURL: String
    var apiKey: String
    var model: String
    var params: ModelParams
    var isRemote: Bool
    var contextSizeOverride: Int?
    var provider: EndpointProvider
    /// Optionales, kleineres/schnelleres Modell (auf demselben Endpunkt) NUR für Hintergrund-Jobs
    /// (Titel-Generierung, Bild-Beschreibung, Zusammenfassung) – spart RAM/Zeit gegenüber dem
    /// vollen Chat-Modell. Leer = Hintergrund-Jobs nutzen dasselbe Modell wie der Chat.
    var backgroundJobModel: String = ""
    /// Exakter LM Studio-Modell-Hub-Bezeichner für das automatische Laden/Entladen via API
    /// (z.B. "bartowski/Qwen2.5-7B-Instruct-GGUF"). Leer = `model`-Feld wird verwendet.
    var lmStudioModelId: String = ""
    /// Wie `lmStudioModelId`, aber für das Hintergrund-Modell. Leer = `backgroundJobModel` wird verwendet.
    var backgroundJobModelLMStudioId: String = ""

    // Audit 2.7: Die Legacy-computed-property `useNativeMetricsEndpoint` hatte 0 Aufrufer
    // (die JSON-Migration decodiert das Legacy-Bool weiter unten direkt aus dem Container) –
    // toter Code, entfernt.

    init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        apiKey: String = "",
        model: String = "local-model",
        params: ModelParams = .empty,
        isRemote: Bool = false,
        contextSizeOverride: Int? = nil,
        provider: EndpointProvider = .openAICompatible,
        backgroundJobModel: String = "",
        lmStudioModelId: String = "",
        backgroundJobModelLMStudioId: String = ""
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.params = params
        self.isRemote = isRemote
        self.contextSizeOverride = contextSizeOverride
        self.provider = provider
        self.backgroundJobModel = backgroundJobModel
        self.lmStudioModelId = lmStudioModelId
        self.backgroundJobModelLMStudioId = backgroundJobModelLMStudioId
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL, apiKey, model, params, isRemote, contextSizeOverride
        case provider, useNativeMetricsEndpoint, backgroundJobModel
        case lmStudioModelId, backgroundJobModelLMStudioId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        apiKey = try c.decode(String.self, forKey: .apiKey)
        model = try c.decode(String.self, forKey: .model)
        params = try c.decode(ModelParams.self, forKey: .params)
        isRemote = try c.decode(Bool.self, forKey: .isRemote)
        contextSizeOverride = try c.decodeIfPresent(Int.self, forKey: .contextSizeOverride)
        backgroundJobModel = try c.decodeIfPresent(String.self, forKey: .backgroundJobModel) ?? ""
        lmStudioModelId = try c.decodeIfPresent(String.self, forKey: .lmStudioModelId) ?? ""
        backgroundJobModelLMStudioId = try c.decodeIfPresent(String.self, forKey: .backgroundJobModelLMStudioId) ?? ""
        // Migration: useNativeMetricsEndpoint (Bool) → provider (EndpointProvider)
        if let prov = try c.decodeIfPresent(EndpointProvider.self, forKey: .provider) {
            provider = prov
        } else {
            let legacy = try c.decodeIfPresent(Bool.self, forKey: .useNativeMetricsEndpoint) ?? false
            provider = legacy ? .lmStudioNative : .openAICompatible
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(apiKey, forKey: .apiKey)
        try c.encode(model, forKey: .model)
        try c.encode(params, forKey: .params)
        try c.encode(isRemote, forKey: .isRemote)
        try c.encodeIfPresent(contextSizeOverride, forKey: .contextSizeOverride)
        try c.encode(provider, forKey: .provider)
        try c.encode(backgroundJobModel, forKey: .backgroundJobModel)
        try c.encode(lmStudioModelId, forKey: .lmStudioModelId)
        try c.encode(backgroundJobModelLMStudioId, forKey: .backgroundJobModelLMStudioId)
    }

    // MARK: - Schnell-Presets

    static let presets: [(name: String, provider: EndpointProvider, baseURL: String, model: String)] = [
        ("LM Studio (lokal)",    .lmStudioNative,   "http://localhost:1234",          "local-model"),
        ("Ollama (lokal)",       .ollama,            "http://localhost:11434",         "llama3.2"),
        ("MLX (lokal)",          .mlx,               "http://localhost:8080",          "mlx-community/Llama-3.2-3B-Instruct-4bit"),
        ("OMLX (lokal)",         .openAICompatible,  "http://127.0.0.1:8072/v1",       "local-model"),
        ("OpenAI",               .openAICompatible,  "https://api.openai.com",        "gpt-4o"),
        ("Groq",                 .openAICompatible,  "https://api.groq.com/openai",   "llama-3.3-70b-versatile"),
        ("Together AI",          .openAICompatible,  "https://api.together.ai",       "meta-llama/Llama-3.3-70B-Instruct-Turbo"),
        ("llama.cpp lokal",      .openAICompatible,  "http://localhost:8080",          "local-model"),
    ]
}
