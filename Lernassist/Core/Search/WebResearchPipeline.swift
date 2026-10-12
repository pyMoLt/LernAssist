import Foundation

/// Ein ausgewählter Beleg-Absatz, wie er an das Modell geht.
nonisolated struct EvidencePassage: Equatable, Sendable {
    let number: Int
    let title: String
    let url: String
    let domain: String
    let published: String?
    let source: ResearchSource
    let text: String
    let score: Double
}

nonisolated struct ResearchResult: Equatable, Sendable {
    var query: String
    var passages: [EvidencePassage]
    var consultedSources: [ResearchSource]
    var usedReranker: Bool
    var notes: [String]

    /// Text für das Modell – nummerierte Belege `[W1]…` mit Titel, Domain, Datum, URL.
    var modelText: String {
        guard !passages.isEmpty else {
            var text = "Für „\(query)“ wurden keine passenden Belege gefunden."
            if !notes.isEmpty { text += "\nHinweise: " + notes.joined(separator: "; ") }
            text += "\nSag dem Nutzer ehrlich, dass die Suche nichts Verlässliches ergeben hat, statt etwas zu erfinden. Eine anders formulierte Suche ist möglich."
            return text
        }
        let ranking = usedReranker ? "Reranker" : "Keyword-Relevanz"
        var lines = ["Belege zu „\(query)“ (Quellen: \(consultedSources.map(\.label).joined(separator: ", ")); sortiert nach \(ranking)):", ""]
        for number in Array(Set(passages.map(\.number))).sorted() {
            let group = passages.filter { $0.number == number }
            guard let first = group.first else { continue }
            var header = "[W\(number)] \(first.title) — \(first.domain)"
            if let date = first.published?.prefix(10), !date.isEmpty { header += " (\(date))" }
            lines.append(header)
            lines.append("URL: \(first.url)")
            lines.append(group.map(\.text).joined(separator: "\n[…]\n"))
            lines.append("")
        }
        lines.append("Nutze diese Belege für Fakten aus der Suche und zitiere sie mit [W1], [W2] … Wenn sie die Frage nicht beantworten, sag das.")
        return lines.joined(separator: "\n")
    }
}

/// Der Ablauf der Websuche – das Modell liefert nur die Suchanfrage, alles Weitere läuft im Code:
///
/// ```
/// Quellen parallel (SearXNG, Wikipedia, Europe PMC, arXiv, Stack Exchange)
///  → Exa-MCP nur, wenn zu wenige Web-Treffer kamen
///  → Sperrliste + Dedup → Volltext der besten Webseiten (WebFetcher + ContentExtractor)
///  → Absätze → Keyword-Filter + BM25 → optional Reranker (Qwen3-Reranker über oMLX)
///  → Top-Absätze (max. pro Quelle, Token-Budget) als [W#]-Belege
/// ```
nonisolated struct WebResearchPipeline: Sendable {
    let settings: ResearchSettings
    let searxngURL: String
    var reranker: Reranker?
    var exaAPIKey: String = ""
    /// Für Tests austauschbar.
    var sourceOverride: [SearchSource]? = nil
    var fetchDocument: (@Sendable (SearchHit, ResearchSettings) async -> [String]?)? = nil

    func run(_ rawQuery: String) async -> ResearchResult {
        let query = String(rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        var notes: [String] = []
        let sources = sourceOverride ?? defaultSources(including: false)

        // 1. Quellen parallel
        var hits: [SearchHit] = []
        var consulted: [ResearchSource] = []
        await withTaskGroup(of: (ResearchSource, Result<[SearchHit], Error>).self) { group in
            for source in sources where source.id != .exa {
                group.addTask {
                    do { return (source.id, .success(try await source.search(query, limit: settings.resultsPerSource))) }
                    catch { return (source.id, .failure(error)) }
                }
            }
            for await (id, result) in group {
                consulted.append(id)
                switch result {
                case .success(let found): hits += found
                case .failure(let error): notes.append("\(id.label): \(error.localizedDescription)")
                }
            }
        }

        // 2. Exa nur als Fallback bei zu wenigen Web-Treffern
        let webHits = hits.filter { $0.source == .searxng }.count
        if settings.enabledSources.contains(.exa), webHits < settings.exaMinWebResults {
            // Mit überschriebenen Quellen (Tests) nur deren Exa – nie ungefragt das Netz.
            let exa: SearchSource? = sourceOverride != nil
                ? sourceOverride?.first(where: { $0.id == .exa })
                : ExaSource(apiKey: exaAPIKey)
            if let exa {
                do {
                    hits += try await exa.search(query, limit: settings.exaResults)
                    consulted.append(.exa)
                } catch {
                    notes.append("Exa: \(error.localizedDescription)")
                }
            }
        }

        // 3. Sperrliste + Dedup (Treffer mit mitgeliefertem Text bevorzugen)
        var byKey: [String: SearchHit] = [:]
        for hit in hits where settings.tier(of: hit.domain) != .blocked {
            if let kept = byKey[hit.key], (kept.blocks?.count ?? 0) >= (hit.blocks?.count ?? 0) { continue }
            byKey[hit.key] = hit
        }
        var unique = Array(byKey.values)
        let queryTokens = PassageRanker.tokens(query)

        // 4. Volltexte für die besten Webtreffer ohne mitgelieferten Text
        let needText = unique.enumerated().filter { $0.element.blocks == nil }
        let snippetScores = PassageRanker.bm25(documents: needText.map { PassageRanker.tokens($0.element.title + " " + $0.element.snippet) },
                                               query: queryTokens)
        let fetchOrder = needText.indices.sorted {
            let a = snippetScores[$0] + settings.tierBonus(of: needText[$0].element.domain) * 3 - Double(needText[$0].element.rank) * 0.05
            let b = snippetScores[$1] + settings.tierBonus(of: needText[$1].element.domain) * 3 - Double(needText[$1].element.rank) * 0.05
            return a > b
        }.prefix(settings.fullTextPages)
        let fetcher = fetchDocument ?? Self.fetchBlocks
        await withTaskGroup(of: (Int, [String]?).self) { group in
            for position in fetchOrder {
                let (index, hit) = needText[position]
                group.addTask { (index, await fetcher(hit, settings)) }
            }
            for await (index, blocks) in group {
                if let blocks, !blocks.isEmpty { unique[index].blocks = blocks }
            }
        }

        // 5. Absätze bilden (ohne Volltext: Snippet als Mini-Absatz)
        struct Candidate { let hit: SearchHit; let passage: Passage; let tokens: [String] }
        var candidates: [Candidate] = []
        for hit in unique {
            let blocks = hit.blocks ?? (hit.snippet.isEmpty ? [] : [hit.title + ": " + hit.snippet])
            for (i, piece) in PassageRanker.split(blocks, target: settings.passageChars).enumerated() {
                candidates.append(Candidate(hit: hit, passage: Passage(sourceKey: hit.key, index: i, text: piece),
                                            tokens: PassageRanker.tokens(piece)))
            }
        }
        guard !candidates.isEmpty else {
            return ResearchResult(query: query, passages: [], consultedSources: consulted, usedReranker: false, notes: notes)
        }

        // 6. Keyword-Relevanz: Die gesuchten Begriffe müssen wirklich vorkommen.
        let lexical = PassageRanker.bm25(documents: candidates.map(\.tokens), query: queryTokens)
        let minCoverage = queryTokens.count >= 3 ? 0.34 : 0.01
        var window = candidates.indices.filter {
            queryTokens.isEmpty || PassageRanker.coverage(of: candidates[$0].tokens, query: queryTokens) >= minCoverage
        }
        window.sort { lexical[$0] > lexical[$1] }
        window = Array(window.prefix(60))
        let topLexical = window.map { lexical[$0] }.max() ?? 1

        // 7. Optional Reranker
        var rerankScores: [Double]? = nil
        if settings.rerankerMode == .auto, let reranker, !window.isEmpty {
            do {
                rerankScores = try await reranker.scores(query: query, documents: window.map { candidates[$0].passage.text })
            } catch {
                notes.append("Reranker nicht verfügbar (\(error.localizedDescription)) – Keyword-Relevanz genutzt")
            }
        }

        var scored: [(index: Int, score: Double)] = window.enumerated().map { position, index in
            let normLexical = topLexical > 0 ? lexical[index] / topLexical : 0
            let bonus = settings.tierBonus(of: candidates[index].hit.domain)
            let prose = PassageRanker.proseQuality(candidates[index].passage.text)
            if let rerankScores {
                return (index, rerankScores[position] * prose + bonus + 0.1 * normLexical)
            }
            return (index, normLexical * prose + bonus)
        }
        scored.sort { $0.score > $1.score }

        // 8. Auswahl: max. Absätze, max. pro Quelle, Token-Budget
        var chosen: [EvidencePassage] = []
        var perSource: [String: Int] = [:]
        var budget = settings.tokenBudget
        var numberBySource: [String: Int] = [:]
        for (index, score) in scored {
            if chosen.count >= settings.maxPassages { break }
            let candidate = candidates[index]
            let key = candidate.hit.key
            if perSource[key, default: 0] >= settings.maxPassagesPerSource { continue }
            let cost = PassageRanker.estimatedTokens(candidate.passage.text) + 30
            if cost > budget { continue }
            budget -= cost
            perSource[key, default: 0] += 1
            // Gleiche Quelle → gleiche Belegnummer, damit Zitate eindeutig bleiben.
            let number = numberBySource[key] ?? (numberBySource.count + 1)
            numberBySource[key] = number
            chosen.append(EvidencePassage(number: number, title: candidate.hit.title, url: candidate.hit.url,
                                          domain: candidate.hit.domain, published: candidate.hit.published,
                                          source: candidate.hit.source, text: candidate.passage.text, score: score))
        }
        chosen.sort { $0.number != $1.number ? $0.number < $1.number : $0.score > $1.score }
        return ResearchResult(query: query, passages: chosen, consultedSources: consulted.sorted { $0.rawValue < $1.rawValue },
                              usedReranker: rerankScores != nil, notes: notes)
    }

    func defaultSources(including exa: Bool) -> [SearchSource] {
        var list: [SearchSource] = []
        let enabled = settings.enabledSources
        if enabled.contains(.searxng), !searxngURL.trimmingCharacters(in: .whitespaces).isEmpty {
            list.append(SearXNGSource(baseURL: searxngURL))
        }
        let agent = settings.apiUserAgent
        if enabled.contains(.wikipedia) { list.append(WikipediaSource(userAgent: agent, language: settings.wikipediaLanguage)) }
        if enabled.contains(.europePMC) { list.append(EuropePMCSource(userAgent: agent)) }
        if enabled.contains(.arxiv) { list.append(ArxivSource(userAgent: agent)) }
        if enabled.contains(.stackExchange) { list.append(StackExchangeSource(userAgent: agent, sites: settings.stackExchangeSites)) }
        if exa, enabled.contains(.exa) { list.append(ExaSource(apiKey: exaAPIKey)) }
        return list
    }

    /// Volltext einer Webseite: Abruf mit Limits, Extraktion, Bot-Seiten verwerfen.
    /// Wikipedia-Links gehen über die API (sauberer Text).
    @Sendable static func fetchBlocks(_ hit: SearchHit, _ settings: ResearchSettings) async -> [String]? {
        if let host = URL(string: hit.url)?.host, host.hasSuffix("wikipedia.org"),
           let title = URL(string: hit.url)?.lastPathComponent.removingPercentEncoding {
            let lang = host.components(separatedBy: ".").first ?? "de"
            if let blocks = try? await WikipediaSource.article(title: title, lang: lang, userAgent: settings.apiUserAgent), !blocks.isEmpty { return blocks }
        }
        guard let url = URL(string: hit.url) else { return nil }
        let fetcher = WebFetcher(timeout: settings.fetchTimeout, maxBytes: Int(settings.maxDownloadMB * 1_048_576))
        guard let page = try? await fetcher.fetch(url),
              let document = try? ContentExtractor.extract(page),
              !ContentExtractor.looksLikeBotPage(document) else { return nil }
        return document.blocks
    }
}
