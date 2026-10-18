import Foundation
import os

// MARK: - Suchergebnis

struct SearchResult: Sendable {
    let title: String
    let url: String
    let snippet: String
    /// Von SearXNG gelieferte Relevanz. DuckDuckGo-Treffer verwenden den Standardwert 0.
    let providerScore: Double

    init(title: String, url: String, snippet: String, providerScore: Double = 0) {
        self.title = String(title.prefix(300))
        self.url = String(url.prefix(2_048))
        self.snippet = String(snippet.prefix(600))
        self.providerScore = providerScore
    }
}

/// Gemeinsame, flüchtige Begrenzung für alle Chats. Reservierte Startzeiten verhindern,
/// dass parallel eingehende Modell-Calls gleichzeitig an SearXNG weitergereicht werden.
actor SearchRequestPacing {
    private var nextStart: [String: Date] = [:]
    private var pauses: [String: (until: Date, code: Int)] = [:]
    private let minimumSpacing: TimeInterval
    private let jitterRange: ClosedRange<Double>

    init(minimumSpacing: TimeInterval = 1.2, jitterRange: ClosedRange<Double> = 0...0.4) {
        self.minimumSpacing = minimumSpacing
        self.jitterRange = jitterRange
    }

    func waitTurn(for backend: String) async throws {
        let now = Date()
        if let pause = pauses[backend], pause.until.timeIntervalSince(now) > 15 {
            throw SearchService.SearchError.rateLimited(pause.code, pause.until.timeIntervalSince(now))
        }
        let start = max(now, nextStart[backend] ?? now, pauses[backend]?.until ?? now)
        nextStart[backend] = start.addingTimeInterval(minimumSpacing + Double.random(in: jitterRange))
        let initialWait = start.timeIntervalSinceNow
        if initialWait > 0 {
            try await Task.sleep(nanoseconds: UInt64(initialWait * 1_000_000_000))
        }
        // Ein 429 kann eintreffen, während dieser Call bereits in der Warteschlange liegt.
        while let pause = pauses[backend], pause.until > Date() {
            try Task.checkCancellation()
            let remaining = pause.until.timeIntervalSinceNow
            if remaining > 15 { throw SearchService.SearchError.rateLimited(pause.code, remaining) }
            try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        try Task.checkCancellation()
    }

    func pause(_ backend: String, for seconds: TimeInterval, code: Int) {
        let until = Date().addingTimeInterval(max(0, seconds))
        if let existing = pauses[backend], existing.until > until { return }
        pauses[backend] = (until, code)
    }
}

/// Nur im RAM, höchstens 100 erfolgreiche Abfragen für maximal drei Minuten. Damit wächst
/// nach vielen Sessions kein Suchverzeichnis auf Platte und alte Antworten verfallen rasch.
actor SearchResultCache {
    private struct Entry {
        let results: [SearchResult]
        let expires: Date
        var lastAccess: Date
    }
    private var entries: [String: Entry] = [:]
    private let lifetime: TimeInterval
    private let limit: Int

    init(lifetime: TimeInterval = 180, limit: Int = 100) {
        self.lifetime = lifetime
        self.limit = limit
    }

    func get(_ key: String) -> [SearchResult]? {
        let now = Date()
        guard var entry = entries[key] else { return nil }
        guard entry.expires > now else {
            entries.removeValue(forKey: key)
            return nil
        }
        entry.lastAccess = now
        entries[key] = entry
        return entry.results
    }

    func put(_ results: [SearchResult], for key: String) {
        let now = Date()
        entries = entries.filter { $0.value.expires > now }
        entries[key] = Entry(results: results, expires: now.addingTimeInterval(lifetime), lastAccess: now)
        if entries.count > limit,
           let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            entries.removeValue(forKey: oldest)
        }
    }
}

// MARK: - SearchService

/// Websuche-Backend für den Lernassistenten.
///
/// Unterstützte Backends:
///   • SearXNG  – eigene Instanz (Docker); Upstream-Engines können trotzdem begrenzen
///   • DuckDuckGo Instant Answers – zero Setup, nur für einfache Faktenfragen
///
/// Schnellstart SearXNG mit Docker:
///   docker run -d -p 8082:8080 --name searxng searxng/searxng
///   → auf dem Rechner mit dem Container: http://127.0.0.1:8082
///   → von einem anderen Gerät: http://<hostname-oder-ip>:8082 (niemals localhost)
class SearchService {
    static let shared = SearchService()

    private let pacing = SearchRequestPacing()
    private let cache = SearchResultCache()
    private let networkSession: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        networkSession = URLSession(configuration: configuration)
    }

    // MARK: - Öffentliche API

    /// Führt eine Suche durch.
    /// - Parameters:
    ///   - query: Suchanfrage
    ///   - baseURL: SearXNG-Basis-URL (z.B. „http://127.0.0.1:8082").
    ///              Bei leerem String wird bewusst DuckDuckGo als einfacher Fallback verwendet.
    /// - Returns: Bis zu 5 Treffer
    func search(query: String, baseURL: String, limit: Int = 5) async throws -> [SearchResult] {
        // Abbruchpunkt (Audit T8): Bei gecanceltem Tool-Call nicht weiter Requests starten.
        try Task.checkCancellation()
        let trimmedQuery = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        guard !trimmedQuery.isEmpty else {
            AppLog.tools.info("Suchanfrage ist leer, überspringe Suche.")
            return []
        }

        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let backend = trimmed.isEmpty ? "https://api.duckduckgo.com" : trimmed.lowercased()
        let key = backend + "|general|auto|\(limit)|" + trimmedQuery
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let cached = await cache.get(key) { return cached }

        // Die Chat-TaskGroup darf mehrere Aufrufe parallel starten. Der gemeinsame Actor
        // reserviert für ALLE Chats dieser App getrennte Startzeiten mit positivem Jitter.
        try await pacing.waitTurn(for: backend)
        try Task.checkCancellation()
        if let cached = await cache.get(key) { return cached }

        guard !trimmed.isEmpty else {
            // Ein leer konfiguriertes Backend ist eine explizite Entscheidung für den einfachen
            // DDG-Fallback. Bei einer *gesetzten*, aber kaputten SearXNG-Adresse dagegen darf
            // nicht still ein anderer Dienst antworten: Instant Answers sind keine Volltextsuche
            // und lieferten dadurch für „Berlin Wetter“ oder das Trump-Kabinett falsche Treffer.
            let response = try await duckduckgo(query: trimmedQuery, backend: backend)
            if response.cacheable { await cache.put(response.results, for: key) }
            return response.results
        }

        let response = try await searxng(query: trimmedQuery, baseURL: trimmed, backend: backend, limit: limit)
        guard !response.results.isEmpty else {
            throw SearchError.noResults
        }
        if response.cacheable { await cache.put(response.results, for: key) }
        return response.results
    }

    /// Formatiert Suchergebnisse als kompakter Markdown-String für das Modell.
    static func formatResults(_ results: [SearchResult], query: String) -> String {
        guard !results.isEmpty else {
            return "Keine Suchergebnisse für \"\(query)\" gefunden."
        }
        var lines = ["Suchergebnisse für \"\(query)\":"]
        for (i, r) in results.enumerated() {
            lines.append("\n\(i + 1). **\(r.title)**")
            lines.append("   URL: \(r.url)")
            if !r.snippet.isEmpty {
                // Snippet auf 300 Zeichen kürzen
                let s = r.snippet.count > 300 ? String(r.snippet.prefix(300)) + "…" : r.snippet
                lines.append("   \(s)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - SearXNG

    private func searxng(query: String, baseURL: String, backend: String, limit: Int) async throws -> (results: [SearchResult], cacheable: Bool) {
        var base = baseURL
        if !base.lowercased().hasPrefix("http") { base = "http://" + base }
        while base.hasSuffix("/") { base = String(base.dropLast()) }

        var components = URLComponents(string: base + "/search")
        components?.queryItems = [
            URLQueryItem(name: "q",          value: query),
            URLQueryItem(name: "format",      value: "json"),
            URLQueryItem(name: "categories",  value: "general"),
            URLQueryItem(name: "language",    value: "auto"),
        ]
        guard let url = components?.url else { throw SearchError.invalidURL }

        // 70s statt vormals 35s: bei langsamer/instabiler eigener Internetverbindung (WLAN) oder
        // remote per Tailscale erreichter SearXNG-Instanz kann schon der Client->SearXNG-
        // Roundtrip selbst spürbar länger dauern, zusätzlich zu der Zeit, die SearXNG intern auf
        // langsame Upstream-Engines wartet – ein zu knappes Client-Timeout hätte die Verbindung
        // sonst abgebrochen, bevor SearXNG überhaupt fertig aggregieren konnte.
        var req = URLRequest(url: url, timeoutInterval: 70)
        req.setValue("LernAssist/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await networkSession.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if http.statusCode == 429 || http.statusCode == 503 {
                let delay = Self.retryDelay(from: http, fallback: http.statusCode == 429 ? 5 : 3)
                await pacing.pause(backend, for: delay, code: http.statusCode)
                throw SearchError.rateLimited(http.statusCode, delay)
            }
            throw SearchError.httpError(http.statusCode)
        }

        guard
            let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let results = json["results"] as? [[String: Any]]
        else { throw SearchError.parseError }

        // Falls SearXNG meldet, dass einzelne Engines nicht geantwortet haben, geben wir das als
        // Diagnose-Hinweis mit aus – hilfreich, wenn "Zeitüberschreitung" pro Engine auftritt
        // (typischerweise ein Problem der SearXNG-Instanz/ihrer Netzwerkanbindung, nicht von
        // LernAssist selbst, siehe Kommentar in unresponsiveEnginesHint()).
        if let hint = unresponsiveEnginesHint(json) {
            AppLog.tools.info("SearXNG meldet nicht-antwortende Engines: \(hint)")
        }

        let parsed = results.compactMap { r -> SearchResult? in
            guard
                let title = r["title"] as? String,
                let urlStr = r["url"] as? String
            else { return nil }
            let snippet = (r["content"] as? String) ?? ""
            let providerScore = (r["score"] as? NSNumber)?.doubleValue ?? 0
            return SearchResult(title: title, url: urlStr, snippet: snippet,
                                providerScore: providerScore)
        }

        // SearXNG gruppiert Treffer mehrerer Engines nicht immer sauber nach Bedeutung. Vorher
        // wurde sogar VOR dem Parsen auf die ersten fünf Rohobjekte gekürzt. Damit fielen gute
        // Treffer, z.B. Senate.gov oder die konkrete Kabinett-Seite, hinter generischen
        // „Donald Trump – Wikipedia“-Treffern weg. Erst alle Treffer bewerten, dann kürzen.
        return (Self.rankResults(parsed, for: query, limit: limit), Self.mayCache(response))
    }

    /// Sortiert SearXNG-Treffer nach Textbezug zur tatsächlichen Anfrage und erst danach nach
    /// dem vom Provider gelieferten Score. Intern, damit die Regression ohne Netzwerk testbar ist.
    static func rankResults(_ results: [SearchResult], for query: String, limit: Int = 5) -> [SearchResult] {
        guard limit > 0 else { return [] }
        let terms = queryTerms(in: query)
        guard !terms.isEmpty else { return Array(results.prefix(limit)) }

        let scored = results.enumerated().map { index, result -> (result: SearchResult, index: Int, matches: Int, score: Double) in
            let title = normalizedText(result.title)
            let snippet = normalizedText(result.snippet)
            let url = normalizedText(result.url)
            let matchingTerms = terms.filter { term in
                title.contains(term) || snippet.contains(term) || url.contains(term)
            }
            let titleMatches = terms.filter { title.contains($0) }.count
            let snippetMatches = terms.filter { snippet.contains($0) }.count
            let coverage = Double(matchingTerms.count) / Double(terms.count)

            // Titel-Treffer und vollständige Abdeckung sind wesentlich aussagekräftiger als
            // ein zufälliger, engine-spezifischer Score. Der Provider-Score bleibt nur Tie-Breaker.
            let score = coverage * 100
                + Double(titleMatches) * 12
                + Double(snippetMatches) * 4
                + result.providerScore
            return (result, index, matchingTerms.count, score)
        }

        // Irrelevante Ausreißer (z.B. Pizza in Redmond für „Berlin Wetter“) nicht unter die
        // besten fünf mischen, sobald es überhaupt passende Treffer gibt.
        let relevant = scored.filter { $0.matches > 0 }
        let candidates = relevant.isEmpty ? scored : relevant
        return candidates
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.index < $1.index
            }
            .prefix(limit)
            .map(\.result)
    }

    private static func queryTerms(in query: String) -> [String] {
        let ignored: Set<String> = [
            "a", "an", "and", "der", "die", "das", "den", "dem", "des", "ein", "eine", "einem", "einen", "einer",
            "for", "from", "in", "ist", "mit", "of", "on", "or", "the", "to", "und", "von", "zu"
        ]
        return Array(Set(
            normalizedText(query)
                .split(separator: " ")
                .map(String.init)
                .filter { $0.count >= 3 && !ignored.contains($0) }
        ))
    }

    private static func normalizedText(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: " ")
    }

    /// Extrahiert SearXNGs eigenes `unresponsive_engines`-Feld (falls vorhanden) für Diagnosezwecke.
    private func unresponsiveEnginesHint(_ json: [String: Any]) -> String? {
        guard let unresponsive = json["unresponsive_engines"] as? [[Any]], !unresponsive.isEmpty else { return nil }
        let names = unresponsive.compactMap { $0.first as? String }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    // MARK: - DuckDuckGo Instant Answers (Fallback, kein API-Key nötig)

    private func duckduckgo(query: String, backend: String) async throws -> (results: [SearchResult], cacheable: Bool) {
        try Task.checkCancellation() // Abbruchpunkt (Audit T8)
        var components = URLComponents(string: "https://api.duckduckgo.com/")
        components?.queryItems = [
            URLQueryItem(name: "q",             value: query),
            URLQueryItem(name: "format",         value: "json"),
            URLQueryItem(name: "no_html",        value: "1"),
            URLQueryItem(name: "skip_disambig",  value: "1"),
        ]
        guard let url = components?.url else { throw SearchError.invalidURL }

        // 15s statt 40s (Audit T8): Die Instant-Answers-API ist ein kleiner Single-Endpoint –
        // antwortet sie nicht in 15 s, ist sie rate-limited (403) oder down. 40 s hätten die
        // Worst-Case-Latenz der kompletten Tool-Kette unnötig verlängert.
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("LernAssist/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await networkSession.data(for: req)
        // HTTP-Status prüfen (Audit T8): DDG rate-limittet mit 403 – vorher wurde die 403-
        // Fehlerseite als "Keine Ergebnisse" geparst statt den klaren Rate-Limit-Fehler zu melden.
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if http.statusCode == 429 || http.statusCode == 503 || http.statusCode == 403 {
                let delay = Self.retryDelay(from: http, fallback: 10)
                await pacing.pause(backend, for: delay, code: http.statusCode)
                throw SearchError.rateLimited(http.statusCode, delay)
            }
            throw SearchError.httpError(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SearchError.parseError
        }

        var results: [SearchResult] = []

        // Abstract (Wikipedia-Zusammenfassung o.Ä.)
        if let abstract = json["AbstractText"] as? String, !abstract.isEmpty,
           let absURL   = json["AbstractURL"] as? String, !absURL.isEmpty {
            let heading = (json["Heading"] as? String) ?? query
            results.append(SearchResult(title: heading, url: absURL, snippet: abstract))
        }

        // Verwandte Themen (aggressive Datenextraktion)
        if let topics = json["RelatedTopics"] as? [[String: Any]] {
            for topic in topics {
                // Manchmal sind Topics in Kategorien geschachtelt ("Topics"-Feld innerhalb eines Topics)
                if let subTopics = topic["Topics"] as? [[String: Any]] {
                    for sub in subTopics {
                        if let res = parseDDGTopic(sub) { results.append(res) }
                    }
                } else if let res = parseDDGTopic(topic) {
                    results.append(res)
                }
                
                if results.count >= 8 { break }
            }
        }

        if results.isEmpty { throw SearchError.noResults }
        return (Array(results.prefix(5)), Self.mayCache(response))
    }

    /// Retry-After kann Sekunden oder ein HTTP-Datum enthalten (RFC 9110). Der Serverwert
    /// wird beachtet; die App setzt nur für fehlende/ungültige Angaben einen kurzen Standard.
    static func retryDelay(from response: HTTPURLResponse, fallback: TimeInterval) -> TimeInterval {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return fallback }
        if let seconds = TimeInterval(value), seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return max(0, date.timeIntervalSinceNow) }
        }
        return fallback
    }

    private static func mayCache(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return true }
        let directive = http.value(forHTTPHeaderField: "Cache-Control")?.lowercased() ?? ""
        return !directive.contains("no-store")
    }

    private func parseDDGTopic(_ dict: [String: Any]) -> SearchResult? {
        guard
            let text     = dict["Text"] as? String, !text.isEmpty,
            let firstURL = dict["FirstURL"] as? String, !firstURL.isEmpty
        else { return nil }
        
        // Titel extrahieren (oft ist der erste Teil vor dem Bindestrich der Titel)
        let titleParts = text.components(separatedBy: " - ")
        let title = titleParts.count > 1 ? titleParts[0] : String(text.prefix(60))
        
        return SearchResult(title: title, url: firstURL, snippet: text)
    }

    // MARK: - Fehlertypen

    enum SearchError: LocalizedError {
        case invalidURL
        case httpError(Int)
        case rateLimited(Int, TimeInterval)
        case parseError
        case noResults

        var errorDescription: String? {
            switch self {
            case .invalidURL:       return "Ungültige Such-URL"
            case .httpError(let c): return "HTTP-Fehler \(c)"
            case .rateLimited(let code, let delay): return "HTTP \(code): Suche vorübergehend begrenzt; nächste Anfrage frühestens in \(Int(ceil(delay))) Sekunden."
            case .parseError:       return "Antwort konnte nicht verarbeitet werden"
            case .noResults:        return "Keine Ergebnisse gefunden"
            }
        }
    }
}
