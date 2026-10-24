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

/// Dauer eines Schritts der Recherche.
nonisolated struct ResearchPhaseTiming: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case sources, fullText, rerank, images }
    var phase: Phase
    var seconds: Double
}

nonisolated struct ResearchResult: Equatable, Sendable {
    var query: String
    var passages: [EvidencePassage]
    var consultedSources: [ResearchSource]
    var usedReranker: Bool
    var notes: [String]
    /// Abbildungen, die das Modell mit [B#] zeigen kann (lokale Nummern 1…n).
    var images: [ResearchImageRef] = []
    /// Zeiten und Zustand jeder Quelle (für den Tool-Schritt, nicht für das Modell).
    var statuses: [ResearchSourceStatus] = []
    /// Dauer der einzelnen Schritte (Quellen, Volltext, Reranker, Bilder) – für den Tool-Schritt.
    var phases: [ResearchPhaseTiming] = []

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
        lines.append("Nutze diese Belege für Fakten aus der Suche und zitiere sie mit ihrer Nummer in eckigen Klammern, z. B. [W3]. Wenn sie die Frage nicht beantworten, sag das.")
        return lines.joined(separator: "\n") + ResearchImages.modelText(for: images)
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
    var searxngHeaders: [String: String] = [:]
    var reranker: Reranker?
    var exaAPIKey: String = ""
    var braveAPIKey: String = ""
    /// Für Tests austauschbar.
    var sourceOverride: [SearchSource]? = nil
    var fetchDocument: (@Sendable (SearchHit, ResearchSettings) async -> [String]?)? = nil
    /// Für Tests austauschbar: Bilder laden und prüfen.
    var downloadImages: (@Sendable ([PageImage]) async -> [ResearchImageRef])? = nil
    /// Für Tests austauschbar: Abbildungen einer PMC-Artikelseite.
    var fetchFigures: (@Sendable (String) async -> [PageImage])? = nil
    /// Für Tests: eigener Quellen-Zustand (sonst je Lauf ein frischer, damit Tests sich nicht beeinflussen).
    var healthOverride: SourceHealth? = nil

    /// Volltext und Abbildungen einer Seite.
    struct FetchedContent: Sendable {
        var blocks: [String]
        var images: [PageImage]
    }

    func run(_ rawQuery: String) async -> ResearchResult {
        let query = String(rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        var notes: [String] = []
        var phases: [ResearchPhaseTiming] = []
        var phaseStart = Date()
        func endPhase(_ phase: ResearchPhaseTiming.Phase) {
            phases.append(ResearchPhaseTiming(phase: phase, seconds: Date().timeIntervalSince(phaseStart)))
            phaseStart = Date()
        }
        let sources = sourceOverride ?? defaultSources(including: false)

        // 1. Quellen parallel – pausierte überspringen, gemeinsames Zeitbudget (Version 4.0)
        var hits: [SearchHit] = []
        var consulted: [ResearchSource] = []
        var statuses: [ResearchSourceStatus] = []
        let health = sourceOverride == nil ? SourceHealth.shared : (healthOverride ?? SourceHealth())
        var active: [SearchSource] = []
        for source in sources where source.id != .exa && source.id != .brave {
            if let pause = await health.pause(for: source.id) {
                statuses.append(Self.pausedStatus(source.id, pause))
                notes.append("\(source.id.label): " + (pause.reason == .rateLimit ? "pausiert (Anfragegrenze)" : "pausiert (nicht erreichbar)"))
            } else {
                active.append(source)
            }
        }

        enum Outcome: Sendable {
            case finished(ResearchSource, Result<[SearchHit], Error>, Double)
            case budgetExceeded
            case enoughHits
        }
        let sourceBudget = max(5, settings.sourceBudgetSeconds)
        let sourcesStart = Date()
        var pending = Set(active.map(\.id))
        var budgetExceeded = false
        // Früher Abschluss: genug Treffer da → Nachzügler bekommen nur noch eine kurze Gnadenfrist.
        var graceStarted = false
        var finishedEarly = false
        await withTaskGroup(of: Outcome.self) { group in
            for source in active {
                group.addTask {
                    let start = Date()
                    do {
                        let found = try await source.search(query, limit: settings.resultsPerSource)
                        return .finished(source.id, .success(found), Date().timeIntervalSince(start))
                    } catch {
                        return .finished(source.id, .failure(error), Date().timeIntervalSince(start))
                    }
                }
            }
            if !active.isEmpty {
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(sourceBudget * 1_000_000_000))
                    return .budgetExceeded
                }
            }
            for await outcome in group {
                switch outcome {
                case .budgetExceeded:
                    // Nachzügler abbrechen – sie zählen als „zu langsam“ (Ausfall).
                    guard !finishedEarly else { continue }
                    budgetExceeded = true
                    group.cancelAll()
                case .enoughHits:
                    guard !budgetExceeded, !pending.isEmpty else { continue }
                    finishedEarly = true
                    group.cancelAll()
                case .finished(let id, let result, let seconds):
                    guard !budgetExceeded, !finishedEarly, pending.remove(id) != nil else { continue }
                    consulted.append(id)
                    switch result {
                    case .success(let found):
                        hits += found
                        await health.recordSuccess(id)
                        statuses.append(ResearchSourceStatus(source: id, state: found.isEmpty ? .empty : .ok, seconds: seconds, hits: found.count))
                        if sourceOverride == nil { ResearchUsage.record(id) }
                    case .failure(let error):
                        let status = await recordFailure(id, error: error, seconds: seconds, health: health)
                        statuses.append(status)
                        if status.state != .empty { notes.append("\(id.label): \(error.localizedDescription)") }
                        if sourceOverride == nil { ResearchUsage.record(id, error: error.localizedDescription) }
                    }
                    if pending.isEmpty {
                        group.cancelAll()
                    } else if settings.earlyFinishHits > 0, !graceStarted, hits.count >= settings.earlyFinishHits {
                        graceStarted = true
                        group.addTask {
                            try? await Task.sleep(nanoseconds: UInt64(ResearchSettings.earlyFinishGraceSeconds * 1_000_000_000))
                            return .enoughHits
                        }
                    }
                }
            }
        }
        for id in pending {
            if finishedEarly {
                // Genug Treffer von den anderen – kein Ausfall, nur nicht abgewartet.
                statuses.append(ResearchSourceStatus(source: id, state: .skipped, seconds: Date().timeIntervalSince(sourcesStart)))
                continue
            }
            await health.recordFailure(id, kind: .outage, pauseMinutes: settings.sourcePauseMinutes)
            statuses.append(ResearchSourceStatus(source: id, state: .timeout, seconds: sourceBudget))
            notes.append("\(id.label): keine Antwort innerhalb von \(Int(sourceBudget)) s – übersprungen")
        }

        // 2. Exa & Brave Search nur als Fallback bei zu wenigen Web-Treffern
        // Nach frühem Abschluss sind genug Treffer da – kein Fallback nötig.
        let webHits = finishedEarly ? Int.max : hits.filter { $0.source == .searxng }.count
        if settings.enabledSources.contains(.exa), webHits < settings.exaMinWebResults {
            // Mit überschriebenen Quellen (Tests) nur deren Exa – nie ungefragt das Netz.
            let exa: SearchSource? = sourceOverride != nil
                ? sourceOverride?.first(where: { $0.id == .exa })
                : ExaSource(apiKey: exaAPIKey)
            if let exa {
                if let pause = await health.pause(for: .exa) {
                    statuses.append(Self.pausedStatus(.exa, pause))
                } else {
                    let start = Date()
                    do {
                        let found = try await exa.search(query, limit: settings.exaResults)
                        hits += found
                        consulted.append(.exa)
                        await health.recordSuccess(.exa)
                        statuses.append(ResearchSourceStatus(source: .exa, state: found.isEmpty ? .empty : .ok,
                                                             seconds: Date().timeIntervalSince(start), hits: found.count))
                        if sourceOverride == nil { ResearchUsage.record(.exa) }
                    } catch {
                        statuses.append(await recordFailure(.exa, error: error, seconds: Date().timeIntervalSince(start), health: health))
                        notes.append("Exa: \(error.localizedDescription)")
                        if sourceOverride == nil { ResearchUsage.record(.exa, error: error.localizedDescription) }
                    }
                }
            }
        }
        let hasBraveKey = !braveAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if settings.enabledSources.contains(.brave), hasBraveKey, webHits < settings.exaMinWebResults {
            let brave: SearchSource? = sourceOverride != nil
                ? sourceOverride?.first(where: { $0.id == .brave })
                : BraveSearchSource(apiKey: braveAPIKey, userAgent: settings.apiUserAgent)
            if let brave {
                if let pause = await health.pause(for: .brave) {
                    statuses.append(Self.pausedStatus(.brave, pause))
                } else {
                    let start = Date()
                    do {
                        let found = try await brave.search(query, limit: settings.exaResults)
                        hits += found
                        consulted.append(.brave)
                        await health.recordSuccess(.brave)
                        statuses.append(ResearchSourceStatus(source: .brave, state: found.isEmpty ? .empty : .ok,
                                                             seconds: Date().timeIntervalSince(start), hits: found.count))
                        if sourceOverride == nil { ResearchUsage.record(.brave) }
                    } catch {
                        statuses.append(await recordFailure(.brave, error: error, seconds: Date().timeIntervalSince(start), health: health))
                        notes.append("Brave Search: \(error.localizedDescription)")
                        if sourceOverride == nil { ResearchUsage.record(.brave, error: error.localizedDescription) }
                    }
                }
            }
        }

        endPhase(.sources)

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
        let fetcher: @Sendable (SearchHit, ResearchSettings) async -> FetchedContent?
        if let fetchDocument {
            fetcher = { hit, settings in await fetchDocument(hit, settings).map { FetchedContent(blocks: $0, images: []) } }
        } else {
            fetcher = Self.fetchContent
        }
        await withTaskGroup(of: (Int, FetchedContent?).self) { group in
            for position in fetchOrder {
                let (index, hit) = needText[position]
                group.addTask { (index, await fetcher(hit, settings)) }
            }
            for await (index, content) in group {
                if let content, !content.blocks.isEmpty { unique[index].blocks = content.blocks }
                if let content, !content.images.isEmpty { unique[index].images = content.images }
            }
        }

        if !fetchOrder.isEmpty { endPhase(.fullText) }

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
            return ResearchResult(query: query, passages: [], consultedSources: consulted, usedReranker: false, notes: notes,
                                  statuses: statuses, phases: phases)
        }

        // 6. Keyword-Relevanz: Die gesuchten Begriffe müssen wirklich vorkommen.
        let lexical = PassageRanker.bm25(documents: candidates.map(\.tokens), query: queryTokens)
        let minCoverage = queryTokens.count >= 3 ? 0.34 : 0.01
        var window = candidates.indices.filter {
            queryTokens.isEmpty || PassageRanker.coverage(of: candidates[$0].tokens, query: queryTokens) >= minCoverage
        }
        window.sort { lexical[$0] > lexical[$1] }
        window = Array(window.prefix(max(1, settings.rerankerWindow)))
        let topLexical = window.map { lexical[$0] }.max() ?? 1

        // 7. Optional Reranker
        var rerankScores: [Double]? = nil
        if settings.rerankerMode == .auto, let reranker, !window.isEmpty {
            phaseStart = Date()
            do {
                rerankScores = try await reranker.scores(query: query, documents: window.map { candidates[$0].passage.text })
            } catch {
                notes.append("Reranker nicht verfügbar (\(error.localizedDescription)) – Keyword-Relevanz genutzt")
            }
            endPhase(.rerank)
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

        // 9. Abbildungen: alle gefundenen Seiten mit Bildern (zitierte zuerst), zur Frage ranken,
        //    prüfen und laden. Über die Relevanz entscheidet die Rangfolge, nicht das Zitat.
        var images: [ResearchImageRef] = []
        if settings.imagesEnabled {
            phaseStart = Date()
            defer { endPhase(.images) }
            let cited = unique.filter { numberBySource[$0.key] != nil }
            let others = unique.filter { numberBySource[$0.key] == nil }
            var candidates: [(image: PageImage, pageTitle: String)] = (cited + others).flatMap { hit in
                (hit.images ?? []).map { (image: $0, pageTitle: hit.title) }
            }
            // Fachartikel (Open Access): Abbildungen mit Legende nur für die zwei bestplatzierten.
            let figurePages = cited.compactMap { hit in hit.figurePage.map { (page: $0, title: hit.title) } }.prefix(2)
            if !figurePages.isEmpty {
                let loadFigures = fetchFigures ?? { await EuropePMCSource.figures(articlePage: $0) }
                await withTaskGroup(of: [(image: PageImage, pageTitle: String)].self) { group in
                    for item in figurePages {
                        group.addTask { await loadFigures(item.page).map { (image: $0, pageTitle: item.title) } }
                    }
                    for await found in group { candidates += found }
                }
            }
            let picked = await ResearchImages.rank(candidates, query: query,
                                                   reranker: settings.rerankerMode == .auto ? reranker : nil,
                                                   limit: ResearchImages.maxPerSearch + 3)
            if !picked.isEmpty {
                let load = downloadImages ?? { await ResearchImages.downloadAll($0) }
                images = Array(await load(picked).prefix(ResearchImages.maxPerSearch))
            }
        }
        return ResearchResult(query: query, passages: chosen, consultedSources: consulted.sorted { $0.rawValue < $1.rawValue },
                              usedReranker: rerankScores != nil, notes: notes, images: images, statuses: statuses, phases: phases)
    }

    /// Fehler einordnen (Rate-Limit / Ausfall / kein Fehler) und beim Quellen-Zustand verbuchen.
    private func recordFailure(_ id: ResearchSource, error: Error, seconds: Double, health: SourceHealth) async -> ResearchSourceStatus {
        guard let kind = SourceHealth.classify(error) else {
            await health.recordSuccess(id)
            return ResearchSourceStatus(source: id, state: .empty, seconds: seconds)
        }
        let nowPaused = await health.recordFailure(id, kind: kind, pauseMinutes: settings.sourcePauseMinutes)
        let state: ResearchSourceStatus.State = kind == .rateLimit ? .rateLimited
            : (SourceHealth.isConnectionFailure(error) ? .unreachable : .failed)
        var status = ResearchSourceStatus(source: id, state: state, seconds: seconds)
        if nowPaused { status.minutesLeft = Int(settings.sourcePauseMinutes.rounded(.up)) }
        return status
    }

    static func pausedStatus(_ id: ResearchSource, _ pause: SourceHealth.Pause) -> ResearchSourceStatus {
        ResearchSourceStatus(source: id, state: .paused, seconds: nil,
                             minutesLeft: max(1, Int((pause.until.timeIntervalSinceNow / 60).rounded(.up))))
    }

    func defaultSources(including exa: Bool) -> [SearchSource] {
        var list: [SearchSource] = []
        let enabled = settings.enabledSources
        if enabled.contains(.searxng), !searxngURL.trimmingCharacters(in: .whitespaces).isEmpty {
            list.append(SearXNGSource(baseURL: searxngURL, timeout: settings.searxngTimeout, headers: searxngHeaders))
        }
        let agent = settings.apiUserAgent
        if enabled.contains(.wikipedia) {
            list.append(WikipediaSource(userAgent: agent, language: settings.wikipediaLanguage, withImages: settings.imagesEnabled))
        }
        if enabled.contains(.europePMC) { list.append(EuropePMCSource(userAgent: agent)) }
        if enabled.contains(.pubmed) { list.append(PubMedSource()) }
        if enabled.contains(.arxiv) { list.append(ArxivSource(userAgent: agent)) }
        if enabled.contains(.stackExchange) { list.append(StackExchangeSource(userAgent: agent, sites: settings.stackExchangeSites)) }
        // Zusätzliche Quellen bekommen die anonyme Kennung (keine Kontakt-E-Mail).
        if enabled.contains(.openAlex) { list.append(OpenAlexSource()) }
        if enabled.contains(.semanticScholar) { list.append(SemanticScholarSource()) }
        if enabled.contains(.medlinePlus) { list.append(MedlinePlusSource()) }
        if enabled.contains(.openFDA) { list.append(OpenFDASource()) }
        if exa, enabled.contains(.exa) { list.append(ExaSource(apiKey: exaAPIKey)) }
        if exa, enabled.contains(.brave), !braveAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            list.append(BraveSearchSource(apiKey: braveAPIKey, userAgent: agent))
        }
        return list
    }

    /// Volltext einer Webseite: Abruf mit Limits, Extraktion, Bot-Seiten verwerfen.
    /// Wikipedia-Links gehen über die API (sauberer Text).
    @Sendable static func fetchBlocks(_ hit: SearchHit, _ settings: ResearchSettings) async -> [String]? {
        await fetchContent(hit, settings)?.blocks
    }

    /// Volltext samt Abbildungen. Wikipedia-Links gehen über die API (Text + Medienliste).
    @Sendable static func fetchContent(_ hit: SearchHit, _ settings: ResearchSettings) async -> FetchedContent? {
        if let host = URL(string: hit.url)?.host, host.hasSuffix("wikipedia.org"),
           let title = URL(string: hit.url)?.lastPathComponent.removingPercentEncoding {
            let lang = host.components(separatedBy: ".").first ?? "de"
            async let images = settings.imagesEnabled
                ? WikipediaSource.mediaImages(title: title, lang: lang, pageURL: hit.url, userAgent: settings.apiUserAgent) : []
            if let blocks = try? await WikipediaSource.article(title: title, lang: lang, userAgent: settings.apiUserAgent), !blocks.isEmpty {
                return FetchedContent(blocks: blocks, images: await images)
            }
        }
        guard let url = URL(string: hit.url) else { return nil }
        let fetcher = WebFetcher(timeout: settings.fetchTimeout, maxBytes: Int(settings.maxDownloadMB * 1_048_576))
        guard let page = try? await fetcher.fetch(url),
              let document = try? ContentExtractor.extract(page),
              !ContentExtractor.looksLikeBotPage(document) else { return nil }
        return FetchedContent(blocks: document.blocks, images: settings.imagesEnabled ? document.images : [])
    }
}
