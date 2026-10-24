import Foundation

// MARK: - Einstellungen pro Modell (Version 4.0)

/// Einstellungen, die an einem Modell hängen – nicht am Profil. Sie bleiben erhalten, wenn das
/// Modell über einen anderen Anbieter oder ein anderes Profil läuft. `nil` heißt jeweils
/// „nicht festgelegt“: dann gilt der Wert des Profils bzw. der Standard des Servers.
/// Vorrang: Modell > Profil > Server.
nonisolated struct ModelSettings: Codable, Equatable, Sendable {
    // Denken
    var thinking: ThinkingMode?
    /// Denkstärke (`reasoning_effort`, z. B. low/medium/high/xhigh – je nach Modell).
    var reasoningEffort: String?
    var thinkingBudget: Int?
    /// Gedankengang früherer Antworten mitschicken (überschreibt die globale Einstellung).
    var preserveThinking: Bool?

    // Sampling
    var temperature: Double?
    var topP: Double?
    var topK: Int?
    var minP: Double?
    var presencePenalty: Double?
    var repetitionPenalty: Double?
    var maxTokens: Int?

    /// Kontextfenster für Anzeige und Kürzen des Verlaufs.
    var contextWindow: Int?

    /// Antworten live streamen (Standard an). Aus: Die Antwort kommt am Stück – für Server,
    /// die beim Streamen Probleme machen.
    var streaming: Bool?
    /// Bilder an das Modell senden (Standard an). Aus: Screenshots gehen als Textbeschreibung mit.
    var vision: Bool?

    /// Sage-A1.5: eingebaute Selbstprüfung im Gedankengang (`chat_template_kwargs.verification`).
    var verification: Bool?

    /// Weitere Schalter der Chat-Vorlage (`chat_template_kwargs`), als Text: „true“, „false“,
    /// Zahlen oder Text.
    var templateKwargs: [String: String] = [:]

    var isEmpty: Bool { self == ModelSettings() }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case thinking, reasoningEffort, thinkingBudget, preserveThinking
        case temperature, topP, topK, minP, presencePenalty, repetitionPenalty, maxTokens
        case contextWindow, streaming, vision, verification, templateKwargs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        thinking = try? c.decodeIfPresent(ThinkingMode.self, forKey: .thinking)
        reasoningEffort = try? c.decodeIfPresent(String.self, forKey: .reasoningEffort)
        thinkingBudget = try? c.decodeIfPresent(Int.self, forKey: .thinkingBudget)
        preserveThinking = try? c.decodeIfPresent(Bool.self, forKey: .preserveThinking)
        temperature = try? c.decodeIfPresent(Double.self, forKey: .temperature)
        topP = try? c.decodeIfPresent(Double.self, forKey: .topP)
        topK = try? c.decodeIfPresent(Int.self, forKey: .topK)
        minP = try? c.decodeIfPresent(Double.self, forKey: .minP)
        presencePenalty = try? c.decodeIfPresent(Double.self, forKey: .presencePenalty)
        repetitionPenalty = try? c.decodeIfPresent(Double.self, forKey: .repetitionPenalty)
        maxTokens = try? c.decodeIfPresent(Int.self, forKey: .maxTokens)
        contextWindow = try? c.decodeIfPresent(Int.self, forKey: .contextWindow)
        streaming = try? c.decodeIfPresent(Bool.self, forKey: .streaming)
        vision = try? c.decodeIfPresent(Bool.self, forKey: .vision)
        verification = try? c.decodeIfPresent(Bool.self, forKey: .verification)
        templateKwargs = (try? c.decodeIfPresent([String: String].self, forKey: .templateKwargs)) ?? [:]
    }

    /// Schlüssel eines Modells: ohne Pfad und Groß-/Kleinschreibung („mlx-community/Qwen3…“ = „qwen3…“).
    static func key(for model: String) -> String {
        (model.split(separator: "/").last.map(String.init) ?? model)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Wert eines freien Schalters in den passenden JSON-Typ umwandeln.
    static func jsonValue(_ text: String) -> Any {
        let t = text.trimmingCharacters(in: .whitespaces)
        switch t.lowercased() {
        case "true", "an", "on", "yes", "ja": return true
        case "false", "aus", "off", "no", "nein": return false
        default: break
        }
        if let int = Int(t) { return int }
        if let double = Double(t) { return double }
        return t
    }
}

// MARK: - Vorlagen

/// Bekannte Modellfamilien: Welche Sonderschalter sie haben und welche Werte der Hersteller empfiehlt.
nonisolated struct ModelPreset: Sendable {
    let name: String
    /// Teilstrings im Modellnamen (klein geschrieben), an denen die Familie erkannt wird.
    let patterns: [String]
    let summary: String
    /// Stufen für `reasoning_effort`; leer = das Modell kennt keine Stufen.
    let effortLevels: [String]
    let supportsVerification: Bool
    let supportsPreserveThinking: Bool
    /// Herstellerempfehlung, per Knopf übernehmbar.
    let recommended: ModelSettings

    static let all: [ModelPreset] = [
        ModelPreset(
            name: "Sage-A1.5",
            patterns: ["sage-a1.5", "sage-a1_5", "sage_a1.5"],
            summary: L("Qwen3.6-Basis von InternScience. Verification-Modus: Das Modell hält im Gedankengang an, prüft, was belegt ist und was gescheitert ist, und schlägt im selben Durchgang einen besseren Weg ein. Braucht einen System-Prompt (hat LernAssist immer)."),
            effortLevels: [],
            supportsVerification: true,
            supportsPreserveThinking: true,
            recommended: {
                var s = ModelSettings()
                s.temperature = 1.0; s.topP = 0.95; s.topK = 20; s.minP = 0
                return s
            }()),
        ModelPreset(
            name: "Qwen3.8",
            patterns: ["qwen3.8"],
            summary: L("Qwen3.8 kennt Denkstufen über „reasoning_effort“. oMLX reicht den Wert an die Chat-Vorlage weiter."),
            effortLevels: ["low", "medium", "high", "xhigh"],
            supportsVerification: false,
            supportsPreserveThinking: true,
            recommended: ModelSettings()),
        ModelPreset(
            name: "Qwen3.5 / 3.6",
            patterns: ["qwen3.6", "qwen3.5", "qwen3_6", "qwen3_5"],
            summary: L("Qwen3.5/3.6: Denken an/aus und „Preserve Thinking“ für Folgefragen und Tool-Runden."),
            effortLevels: [],
            supportsVerification: false,
            supportsPreserveThinking: true,
            recommended: {
                var s = ModelSettings()
                s.temperature = 0.6; s.topP = 0.95; s.topK = 20; s.minP = 0
                return s
            }()),
    ]

    static func matching(_ model: String) -> ModelPreset? {
        let key = ModelSettings.key(for: model)
        return all.first { preset in preset.patterns.contains { key.contains($0) } }
    }
}

// MARK: - Zugriff für den Request-Builder

/// Aktuelle Modell-Einstellungen (vom ViewModel gesetzt), lesbar von überall – auch außerhalb des
/// Main-Actors, wo Requests gebaut werden.
nonisolated final class ModelSettingsRegistry: @unchecked Sendable {
    static let shared = ModelSettingsRegistry()
    private let lock = NSLock()
    private var byModel: [String: ModelSettings] = [:]

    func update(_ settings: [String: ModelSettings]) {
        lock.withLock { byModel = settings }
    }

    func settings(for model: String) -> ModelSettings {
        lock.withLock { byModel[ModelSettings.key(for: model)] ?? ModelSettings() }
    }
}
