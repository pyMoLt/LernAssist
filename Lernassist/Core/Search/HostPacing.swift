import Foundation

/// Höfliche Abstände pro Host für alle Abrufe der Recherche (Fach-APIs, Volltexte, Exa).
/// Startet das Modell mehrere Suchen gleichzeitig, reserviert der Actor für jeden Host eigene
/// Startzeiten mit etwas Zufall – so gehen nie mehrere Anfragen auf einmal an dieselbe Quelle.
/// Antwortet ein Host mit 429/503, pausiert er für die verlangte Zeit. SearXNG hat seinen eigenen
/// Takt in `SearchRequestPacing`.
actor HostPacing {
    static let shared = HostPacing()

    private var nextStart: [String: Date] = [:]
    private var pausedUntil: [String: Date] = [:]

    /// Mindestabstand zwischen zwei Anfragen an denselben Host, nach den Nutzungsregeln der Dienste.
    nonisolated static func spacing(for host: String) -> TimeInterval {
        let h = host.lowercased()
        switch h {
        case "export.arxiv.org":        return 3.0   // arXiv: etwa eine Anfrage pro 3 s
        case "api.semanticscholar.org": return 1.1   // ohne Key gemeinsamer, knapper Pool
        case "api.stackexchange.com":   return 1.0   // ohne Key 300 Anfragen pro Tag
        case "mcp.exa.ai":              return 1.0
        case "wsearch.nlm.nih.gov":     return 0.8   // MedlinePlus: max. 85 pro Minute
        case "www.ebi.ac.uk":           return 0.5   // Europe PMC: keine feste Grenze, maßvoll
        case "api.fda.gov":             return 0.3   // openFDA: 240 pro Minute
        case "api.openalex.org":        return 0.2   // OpenAlex: 10 pro Sekunde ohne Key
        case "upload.wikimedia.org", "thumb.wikimedia.org": return 0.2   // Bild-CDN von Wikimedia
        case "cdn.ncbi.nlm.nih.gov":    return 0.3   // Abbildungen aus PMC-Artikeln
        default:
            // Wikipedia: Anfragen nacheinander statt gleichzeitig.
            if h.hasSuffix("wikipedia.org") { return 0.5 }
            // Volltext-Seiten beliebiger Websites.
            return 1.0
        }
    }

    /// Wartet, bis dieser Host wieder dran ist. Wirft, wenn er länger als 30 s pausiert.
    func waitTurn(host rawHost: String) async throws {
        let host = rawHost.lowercased()
        let now = Date()
        if let until = pausedUntil[host], until.timeIntervalSince(now) > 30 {
            throw WebFetchError.httpStatus(429)
        }
        let start = max(now, nextStart[host] ?? now, pausedUntil[host] ?? now)
        nextStart[host] = start.addingTimeInterval(Self.spacing(for: host) + Double.random(in: 0...0.3))
        let wait = start.timeIntervalSinceNow
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        try Task.checkCancellation()
    }

    /// Host pausieren (429/503, Stack-Exchange-`backoff`). Eine längere Pause bleibt bestehen.
    func pause(host rawHost: String, seconds: TimeInterval) {
        let host = rawHost.lowercased()
        let until = Date().addingTimeInterval(min(max(seconds, 1), 600))
        if let existing = pausedUntil[host], existing > until { return }
        pausedUntil[host] = until
    }
}
