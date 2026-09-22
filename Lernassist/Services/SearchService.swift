import Foundation
import os

// MARK: - Suchergebnis

struct SearchResult {
    let title: String
    let url: String
    let snippet: String
    /// Von SearXNG gelieferte Relevanz. DuckDuckGo-Treffer verwenden den Standardwert 0.
    let providerScore: Double

    init(title: String, url: String, snippet: String, providerScore: Double = 0) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.providerScore = providerScore
    }
}

// MARK: - SearchService

/// Websuche-Backend für den Lernassistenten.
///
/// Unterstützte Backends:
///   • SearXNG  – lokal (Docker), kein Rate-Limit, empfohlen
///   • DuckDuckGo Instant Answers – zero Setup, nur für einfache Faktenfragen
///
/// Schnellstart SearXNG mit Docker:
///   docker run -d -p 8082:8080 --name searxng searxng/searxng
///   → auf dem Docker-Mac: http://127.0.0.1:8082
///   → von einem anderen Mac: http://<tailscale-hostname>:8082 (niemals localhost)
class SearchService {
    static let shared = SearchService()

    // MARK: - Öffentliche API

    /// Führt eine Suche durch.
    /// - Parameters:
    ///   - query: Suchanfrage
    ///   - baseURL: SearXNG-Basis-URL (z.B. „http://127.0.0.1:8082").
    ///              Bei leerem String wird bewusst DuckDuckGo als einfacher Fallback verwendet.
    /// - Returns: Bis zu 5 Treffer
    func search(query: String, baseURL: String) async throws -> [SearchResult] {
        // Abbruchpunkt (Audit T8): Bei gecanceltem Tool-Call nicht weiter Requests starten.
        try Task.checkCancellation()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            AppLog.tools.info("Suchanfrage ist leer, überspringe Suche.")
            return []
        }

        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Ein leer konfiguriertes Backend ist eine explizite Entscheidung für den einfachen
            // DDG-Fallback. Bei einer *gesetzten*, aber kaputten SearXNG-Adresse dagegen darf
            // nicht still ein anderer Dienst antworten: Instant Answers sind keine Volltextsuche
            // und lieferten dadurch für „Berlin Wetter“ oder das Trump-Kabinett falsche Treffer.
            return try await duckduckgo(query: trimmedQuery)
        }

        let results = try await searxng(query: trimmedQuery, baseURL: trimmed)
        guard !results.isEmpty else {
            throw SearchError.noResults
        }
        return results
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

    private func searxng(query: String, baseURL: String) async throws -> [SearchResult] {
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

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
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
            return SearchResult(title: title, url: urlStr, snippet: snippet, providerScore: providerScore)
        }

        // SearXNG gruppiert Treffer mehrerer Engines nicht immer sauber nach Bedeutung. Vorher
        // wurde sogar VOR dem Parsen auf die ersten fünf Rohobjekte gekürzt. Damit fielen gute
        // Treffer, z.B. Senate.gov oder die konkrete Kabinett-Seite, hinter generischen
        // „Donald Trump – Wikipedia“-Treffern weg. Erst alle Treffer bewerten, dann kürzen.
        return Self.rankResults(parsed, for: query)
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

    private func duckduckgo(query: String) async throws -> [SearchResult] {
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

        let (data, response) = try await URLSession.shared.data(for: req)
        // HTTP-Status prüfen (Audit T8): DDG rate-limittet mit 403 – vorher wurde die 403-
        // Fehlerseite als "Keine Ergebnisse" geparst statt den klaren Rate-Limit-Fehler zu melden.
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
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
        return Array(results.prefix(5))
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
        case parseError
        case noResults

        var errorDescription: String? {
            switch self {
            case .invalidURL:       return "Ungültige Such-URL"
            case .httpError(let c): return "HTTP-Fehler \(c)"
            case .parseError:       return "Antwort konnte nicht verarbeitet werden"
            case .noResults:        return "Keine Ergebnisse gefunden"
            }
        }
    }
}
