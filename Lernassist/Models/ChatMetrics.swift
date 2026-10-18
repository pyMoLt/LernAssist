import Foundation
import Combine

// MARK: - Chat-Metriken

/// Metriken aus dem Streaming-Response. Trennt sauber zwischen:
/// 1. **Prompt Processing (Prefill)**: `promptTokens`, `timeToFirstToken` (TTFT), `prefillTokensPerSecond`, `cachedTokens`
/// 2. **Token Generation (Decode)**: `completionTokens`, `tokensPerSecond` (Decode), `tpsHistory` (Live-Verlaufskurve)
nonisolated struct ChatMetrics: Equatable, Sendable {
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    var cachedTokens: Int = 0               // prompt_tokens_details.cached_tokens (llama.cpp / oMLX)
    var tokensPerSecond: Double?            // Decode-Geschwindigkeit (tok/s)
    var prefillTokensPerSecond: Double?     // Prompt-Processing-Geschwindigkeit (tok/s)
    var timeToFirstToken: Double?           // Sekunden bis zum ersten Output-/Thinking-Token (Prefill-Dauer)
    var totalDuration: Double?              // Gesamtdauer des Requests in Sekunden
    var contextWindowSize: Int?             // Aus /v1/models geladen (Phase 7C)

    // Live-Telemetrie für den mitlaufenden Sparkline-Graphen im Header:
    var isPrefilling: Bool = false          // True während Prompt Processing (vor dem 1. Token)
    var prefillElapsed: Double = 0          // Verstrichene Prefill-Zeit in Sekunden (Live-Ticker)
    var tpsHistory: [Double] = []           // Zeitreihe der Decode-Tok/s (bis zu 28 Messpunkte)

    static let maxHistorySamples = 28

    var totalTokens: Int { promptTokens + completionTokens }
    var cacheHitRate: Double {
        guard promptTokens > 0 else { return 0 }
        return min(1.0, Double(cachedTokens) / Double(promptTokens))
    }

    /// Berechnet Prefill-Tok/s entweder aus dem expliziten Serverwert oder aus `promptTokens / timeToFirstToken`.
    var effectivePrefillTPS: Double? {
        if let p = prefillTokensPerSecond, p > 0 { return p }
        if promptTokens > 0, let ttft = timeToFirstToken, ttft > 0.005 {
            return Double(promptTokens) / ttft
        }
        return nil
    }

    mutating func appendTPSSample(_ value: Double) {
        guard value.isFinite, value > 0 else { return }
        tpsHistory.append(value)
        if tpsHistory.count > Self.maxHistorySamples {
            tpsHistory.removeFirst(tpsHistory.count - Self.maxHistorySamples)
        }
    }

    static let empty = ChatMetrics()
}

// MARK: - Metriken-Parser

nonisolated enum MetricsParser {

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

        // 1. Standard-usage (OpenAI-Format: LM Studio /v1, Ollama /v1, llama.cpp, Groq, oMLX)
        if let usage = json["usage"] as? [String: Any] {
            if let pt = usage["prompt_tokens"] as? Int {
                metrics.promptTokens = pt; hasAny = true
            }
            if let ct = usage["completion_tokens"] as? Int {
                metrics.completionTokens = ct; hasAny = true
            }
            // llama.cpp / OpenAI: usage.prompt_tokens_details.cached_tokens
            if let details = usage["prompt_tokens_details"] as? [String: Any],
               let cached = details["cached_tokens"] as? Int {
                metrics.cachedTokens = cached; hasAny = true
            }
            // 1a. oMLX: Server-Timings direkt im usage-Objekt (Sekunden)
            if let tps = usage["generation_tokens_per_second"] as? Double, tps > 0 {
                metrics.tokensPerSecond = tps; hasAny = true
            }
            if let prefillTps = (usage["prompt_tokens_per_second"] as? Double)
                ?? (usage["prefill_tokens_per_second"] as? Double), prefillTps > 0 {
                metrics.prefillTokensPerSecond = prefillTps; hasAny = true
            }
            if let ttft = usage["time_to_first_token"] as? Double, ttft > 0 {
                metrics.timeToFirstToken = ttft; hasAny = true
            }
            // 1b. Groq: completion_time + prompt_time in usage → exakte TPS
            if let compTime = usage["completion_time"] as? Double, compTime > 0,
               let ct = usage["completion_tokens"] as? Int, ct > 0 {
                metrics.tokensPerSecond = Double(ct) / compTime
                hasAny = true
            }
            if let promptTime = usage["prompt_time"] as? Double, promptTime > 0,
               let pt = usage["prompt_tokens"] as? Int, pt > 0 {
                metrics.prefillTokensPerSecond = Double(pt) / promptTime
                if metrics.timeToFirstToken == nil { metrics.timeToFirstToken = promptTime }
                hasAny = true
            }
        }

        // 2. llama.cpp: timings.predicted_per_second & prompt_per_second
        if let timings = json["timings"] as? [String: Any] {
            if let tps = timings["predicted_per_second"] as? Double, tps > 0 {
                metrics.tokensPerSecond = tps; hasAny = true
            }
            if let promptTps = timings["prompt_per_second"] as? Double, promptTps > 0 {
                metrics.prefillTokensPerSecond = promptTps; hasAny = true
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
                if let promptDur = json["prompt_eval_duration"] as? Double, promptDur > 0 {
                    let sec = promptDur / 1_000_000_000
                    metrics.prefillTokensPerSecond = Double(promptCount) / sec
                    if metrics.timeToFirstToken == nil { metrics.timeToFirstToken = sec }
                }
            }
        }

        if metrics.prefillTokensPerSecond == nil,
           metrics.promptTokens > 0,
           let ttft = metrics.timeToFirstToken, ttft > 0.005 {
            metrics.prefillTokensPerSecond = Double(metrics.promptTokens) / ttft
        }

        return hasAny ? metrics : nil
    }

    /// Merge-Variante: erhält bereits bekannte Felder (inkl. Live-Verlaufskurve `tpsHistory`),
    /// wenn der neue Parse-Durchlauf sie nicht liefert.
    static func parse(fromDict json: [String: Any], mergingInto base: ChatMetrics) -> ChatMetrics? {
        guard var fresh = parse(fromDict: json) else { return nil }
        if fresh.promptTokens == 0 && base.promptTokens > 0 { fresh.promptTokens = base.promptTokens }
        if fresh.completionTokens == 0 && base.completionTokens > 0 { fresh.completionTokens = base.completionTokens }
        if fresh.cachedTokens == 0 && base.cachedTokens > 0 { fresh.cachedTokens = base.cachedTokens }
        if fresh.tokensPerSecond == nil { fresh.tokensPerSecond = base.tokensPerSecond }
        if fresh.contextWindowSize == nil { fresh.contextWindowSize = base.contextWindowSize }
        if fresh.timeToFirstToken == nil { fresh.timeToFirstToken = base.timeToFirstToken }
        if fresh.prefillTokensPerSecond == nil {
            if fresh.promptTokens > 0, let ttft = fresh.timeToFirstToken, ttft > 0.005 {
                fresh.prefillTokensPerSecond = Double(fresh.promptTokens) / ttft
            } else {
                fresh.prefillTokensPerSecond = base.prefillTokensPerSecond
            }
        }
        fresh.tpsHistory = base.tpsHistory
        if let tps = fresh.tokensPerSecond {
            fresh.appendTPSSample(tps)
        }
        return fresh
    }
}


/// Hält die Live-Metriken getrennt vom ChatViewModel (siehe `ChatViewModel.telemetry`).
final class TelemetryStore: ObservableObject {
    @Published var metrics: ChatMetrics = .empty
}
