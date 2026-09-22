import Foundation

// MARK: - Chat-Metriken

/// Metriken aus dem Streaming-Response. Felder die der jeweilige Server nicht liefert
/// bleiben nil — kein harter Fehler. TPS kann server-seitig (LM Studio, Ollama) oder
/// clientseitig berechnet werden (OpenAI, Groq, MLX).
///
/// Quellen:
/// - LM Studio /api/v0: stats.tokens_per_second, stats.time_to_first_token
/// - llama.cpp:         timings.predicted_per_second, usage.prompt_tokens_details.cached_tokens
/// - Ollama /api/chat:  eval_count / eval_duration (ns) = TPS; prompt_eval_count
/// - OpenAI / Groq:     usage.prompt_tokens / completion_tokens; Groq: completion_time für TPS
/// - MLX:               Standard OpenAI usage-Objekt
struct ChatMetrics: Equatable {
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    var cachedTokens: Int = 0       // prompt_tokens_details.cached_tokens (llama.cpp)
    var tokensPerSecond: Double?    // server-seitig oder clientseitig berechnet
    var timeToFirstToken: Double?   // Sekunden bis zum ersten Output-Token (clientseitig gemessen)
    var totalDuration: Double?      // Gesamtdauer des Requests in Sekunden (clientseitig)
    var contextWindowSize: Int?     // Aus /v1/models geladen (Phase 7C)

    var totalTokens: Int { promptTokens + completionTokens }
    var cacheHitRate: Double {
        guard promptTokens > 0 else { return 0 }
        return Double(cachedTokens) / Double(promptTokens)
    }

    static let empty = ChatMetrics()
}

// MARK: - Metriken-Parser

enum MetricsParser {

    /// Versucht Metriken aus einem JSON-String zu lesen. Gibt nil wenn keine verwertbaren Felder.
    static func parse(from jsonStr: String) -> ChatMetrics? {
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parse(fromDict: json)
    }

    static func parse(fromDict json: [String: Any]) -> ChatMetrics? {
        var metrics = ChatMetrics()
        var hasAny = false

        // 1. Standard-usage (OpenAI-Format: LM Studio /v1, Ollama /v1, llama.cpp, Groq, MLX)
        if let usage = json["usage"] as? [String: Any] {
            if let pt = usage["prompt_tokens"] as? Int {
                metrics.promptTokens = pt; hasAny = true
            }
            if let ct = usage["completion_tokens"] as? Int {
                metrics.completionTokens = ct; hasAny = true
            }
            // llama.cpp: usage.prompt_tokens_details.cached_tokens
            if let details = usage["prompt_tokens_details"] as? [String: Any],
               let cached = details["cached_tokens"] as? Int {
                metrics.cachedTokens = cached; hasAny = true
            }
            // 1b. Groq: completion_time + prompt_time in usage → exakte TPS
            if let compTime = usage["completion_time"] as? Double, compTime > 0,
               let ct = usage["completion_tokens"] as? Int, ct > 0 {
                metrics.tokensPerSecond = Double(ct) / compTime
                hasAny = true
            }
        }

        // 2. llama.cpp: timings.predicted_per_second (direkt im letzten SSE-Chunk)
        if let timings = json["timings"] as? [String: Any] {
            if let tps = timings["predicted_per_second"] as? Double, tps > 0 {
                metrics.tokensPerSecond = tps; hasAny = true
            }
            if let cacheN = timings["cache_n"] as? Int, metrics.cachedTokens == 0 {
                metrics.cachedTokens = cacheN; hasAny = true
            }
        }

        // 3. LM Studio /api/v0: stats.tokens_per_second, stats.time_to_first_token
        if let stats = json["stats"] as? [String: Any] {
            if let tps = stats["tokens_per_second"] as? Double, tps > 0 {
                metrics.tokensPerSecond = tps; hasAny = true
            }
            if let ttft = stats["time_to_first_token"] as? Double, ttft > 0 {
                metrics.timeToFirstToken = ttft; hasAny = true
            }
        }

        // 4. Ollama /api/chat: eval_count + eval_duration (Nanosekunden) im done-Chunk
        //    TPS = eval_count / eval_duration × 10⁹
        if let done = json["done"] as? Bool, done {
            if let evalCount = json["eval_count"] as? Int,
               let evalDur = json["eval_duration"] as? Double,
               evalDur > 0 {
                metrics.completionTokens = evalCount
                metrics.tokensPerSecond = Double(evalCount) / evalDur * 1_000_000_000
                hasAny = true
            }
            if let promptCount = json["prompt_eval_count"] as? Int {
                metrics.promptTokens = promptCount; hasAny = true
            }
        }

        return hasAny ? metrics : nil
    }

    /// Merge-Variante: erhält bereits bekannte Felder wenn der neue Parse-Durchlauf sie nicht liefert.
    /// Verhindert Flackern wenn llama.cpp `timings` in JEDEM Chunk schickt, `usage` aber nur im letzten.
    static func parse(fromDict json: [String: Any], mergingInto base: ChatMetrics) -> ChatMetrics? {
        guard var fresh = parse(fromDict: json) else { return nil }
        // Felder aus `base` übernehmen wenn der neue Chunk sie nicht gesetzt hat
        if fresh.promptTokens == 0 && base.promptTokens > 0 { fresh.promptTokens = base.promptTokens }
        if fresh.completionTokens == 0 && base.completionTokens > 0 { fresh.completionTokens = base.completionTokens }
        if fresh.cachedTokens == 0 && base.cachedTokens > 0 { fresh.cachedTokens = base.cachedTokens }
        if fresh.tokensPerSecond == nil { fresh.tokensPerSecond = base.tokensPerSecond }
        if fresh.contextWindowSize == nil { fresh.contextWindowSize = base.contextWindowSize }
        if fresh.timeToFirstToken == nil { fresh.timeToFirstToken = base.timeToFirstToken }
        return fresh
    }
}
