import Foundation

/// Ein Suchtreffer einer Quelle. API-Quellen (Wikipedia, Europe PMC, arXiv, Stack Exchange, Exa)
/// liefern ihren Text gleich mit (`blocks`); Web-Treffer (SearXNG) werden nachgeladen.
nonisolated struct SearchHit: Equatable, Sendable {
    let source: ResearchSource
    var title: String
    var url: String
    var snippet: String
    var published: String?
    var blocks: [String]?
    /// Position in der Ergebnisliste der Quelle (0 = bester Treffer).
    var rank: Int

    var domain: String { URL(string: url)?.host?.lowercased().replacingOccurrences(of: "www.", with: "") ?? "" }

    /// Normalisierte URL für die Duplikaterkennung.
    var key: String {
        guard var c = URLComponents(string: url) else { return url.lowercased() }
        c.scheme = "https"
        c.host = c.host?.lowercased().replacingOccurrences(of: "www.", with: "").replacingOccurrences(of: ".m.wikipedia.org", with: ".wikipedia.org")
        c.fragment = nil
        c.queryItems = c.queryItems?.filter { !$0.name.lowercased().hasPrefix("utm_") && $0.name != "ref" }
        if c.queryItems?.isEmpty == true { c.queryItems = nil }
        var s = c.string ?? url
        while s.hasSuffix("/") { s.removeLast() }
        return s.lowercased()
    }
}

/// Eine Datenquelle der Websuche.
nonisolated protocol SearchSource: Sendable {
    var id: ResearchSource { get }
    func search(_ query: String, limit: Int) async throws -> [SearchHit]
}

/// Gemeinsame JSON-Hilfe für API-Quellen (über den WebFetcher – gleiche Limits und SSRF-Sperre).
nonisolated enum SourceHTTP {
    static let apiUserAgent = "LernAssist/2.0 (macOS learning app; personal use)"

    static func json(_ url: URL, userAgent: String = apiUserAgent, timeout: TimeInterval = 12) async throws -> Any {
        // APIs bekommen eine ehrliche App-Kennung (optional mit Kontakt-E-Mail, siehe
        // ResearchSettings.apiContactEmail).
        let fetcher = WebFetcher(timeout: timeout, maxBytes: 4 * 1_024 * 1_024, userAgent: userAgent)
        let page = try await fetcher.fetch(url, accept: "application/json")
        return try JSONSerialization.jsonObject(with: page.data)
    }

    static func url(_ base: String, _ items: [String: String]) -> URL? {
        var c = URLComponents(string: base)
        c?.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c?.url
    }
}

// MARK: - SearXNG

nonisolated struct SearXNGSource: SearchSource {
    let baseURL: String
    var id: ResearchSource { .searxng }

    func search(_ query: String, limit: Int) async throws -> [SearchHit] {
        let results = try await SearchService.shared.search(query: query, baseURL: baseURL, limit: limit)
        return results.enumerated().map { index, r in
            SearchHit(source: .searxng, title: r.title, url: r.url, snippet: r.snippet, rank: index)
        }
    }
}

// MARK: - Wikipedia (REST-Suche + Klartext-Extrakt)

nonisolated struct WikipediaSource: SearchSource {
    var userAgent: String = SourceHTTP.apiUserAgent
    var language: String = "de"
    /// Für so viele Top-Artikel wird der volle Klartext geladen.
    var fullArticles: Int = 2
    var id: ResearchSource { .wikipedia }

    func search(_ query: String, limit: Int) async throws -> [SearchHit] {
        let lang = language.isEmpty ? "de" : language
        guard let url = SourceHTTP.url("https://\(lang).wikipedia.org/w/rest.php/v1/search/page",
                                       ["q": query, "limit": String(max(1, min(limit, 10)))]),
              let json = try await SourceHTTP.json(url, userAgent: userAgent) as? [String: Any],
              let pages = json["pages"] as? [[String: Any]] else { return [] }

        var hits: [SearchHit] = pages.enumerated().compactMap { index, page in
            guard let key = page["key"] as? String, let title = page["title"] as? String else { return nil }
            let excerpt = ContentExtractor.clean((page["excerpt"] as? String ?? "")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            let path = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
            return SearchHit(source: .wikipedia, title: title, url: "https://\(lang).wikipedia.org/wiki/\(path)",
                             snippet: excerpt, rank: index)
        }
        await withTaskGroup(of: (Int, [String]?).self) { group in
            for index in hits.indices.prefix(fullArticles) {
                let title = hits[index].title
                group.addTask { (index, try? await Self.article(title: title, lang: lang, userAgent: userAgent)) }
            }
            for await (index, blocks) in group where blocks?.isEmpty == false {
                hits[index].blocks = blocks
            }
        }
        return hits
    }

    /// Voller Artikeltext ohne Markup (action=query&prop=extracts&explaintext).
    static func article(title: String, lang: String, userAgent: String = SourceHTTP.apiUserAgent) async throws -> [String] {
        guard let url = SourceHTTP.url("https://\(lang).wikipedia.org/w/api.php", [
            "action": "query", "prop": "extracts", "explaintext": "1", "exsectionformat": "wiki",
            "redirects": "1", "format": "json", "formatversion": "2", "titles": title,
        ]), let json = try await SourceHTTP.json(url, userAgent: userAgent) as? [String: Any],
              let pages = (json["query"] as? [String: Any])?["pages"] as? [[String: Any]],
              let extract = pages.first?["extract"] as? String else { return [] }
        return blocks(fromWikiText: extract)
    }

    /// „== Abschnitt ==“ → „## Abschnitt“, Literatur/Weblinks/Einzelnachweise abschneiden.
    static func blocks(fromWikiText text: String) -> [String] {
        let stopSections = ["literatur", "weblinks", "einzelnachweise", "siehe auch", "references", "external links",
                            "see also", "further reading", "anmerkungen", "quellen"]
        var blocks: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("=="), line.hasSuffix("==") {
                let level = line.prefix(while: { $0 == "=" }).count
                let heading = line.trimmingCharacters(in: CharacterSet(charactersIn: "= "))
                if stopSections.contains(heading.lowercased()) { break }
                blocks.append(String(repeating: "#", count: min(max(level, 2), 4)) + " " + heading)
            } else {
                blocks.append(line)
            }
        }
        return blocks
    }
}

// MARK: - Europe PMC (Abstracts)

nonisolated struct EuropePMCSource: SearchSource {
    var userAgent: String = SourceHTTP.apiUserAgent
    var id: ResearchSource { .europePMC }

    func search(_ query: String, limit: Int) async throws -> [SearchHit] {
        guard let url = SourceHTTP.url("https://www.ebi.ac.uk/europepmc/webservices/rest/search", [
            "query": query + " AND HAS_ABSTRACT:y", "format": "json", "resultType": "core",
            "pageSize": String(max(1, min(limit, 10))),
        ]), let json = try await SourceHTTP.json(url, userAgent: userAgent) as? [String: Any],
              let results = (json["resultList"] as? [String: Any])?["result"] as? [[String: Any]] else { return [] }

        return results.enumerated().compactMap { index, item in
            guard let title = item["title"] as? String,
                  let abstract = item["abstractText"] as? String, !abstract.isEmpty else { return nil }
            let link: String
            if let pmid = item["pmid"] as? String { link = "https://europepmc.org/article/MED/\(pmid)" }
            else if let doi = item["doi"] as? String { link = "https://doi.org/\(doi)" }
            else if let id = item["id"] as? String, let src = item["source"] as? String { link = "https://europepmc.org/article/\(src)/\(id)" }
            else { return nil }
            let journal = ((item["journalInfo"] as? [String: Any])?["journal"] as? [String: Any])?["title"] as? String
            let abstractBlocks = ContentExtractor.extractHTML("<html><body><p>\(abstract)</p></body></html>", url: link).blocks
            let cleanTitle = ContentExtractor.clean(title.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            var blocks = ["# " + cleanTitle]
            if let journal { blocks.append("Journal: \(journal)") }
            blocks += abstractBlocks
            return SearchHit(source: .europePMC, title: cleanTitle, url: link,
                             snippet: String(abstract.prefix(300)), published: item["firstPublicationDate"] as? String ?? item["pubYear"] as? String,
                             blocks: blocks, rank: index)
        }
    }
}

// MARK: - arXiv (Atom-API)

nonisolated struct ArxivSource: SearchSource {
    var userAgent: String = SourceHTTP.apiUserAgent
    var id: ResearchSource { .arxiv }

    func search(_ query: String, limit: Int) async throws -> [SearchHit] {
        let terms = query.split(whereSeparator: \.isWhitespace).map { "all:\($0)" }.joined(separator: " AND ")
        guard let url = SourceHTTP.url("https://export.arxiv.org/api/query", [
            "search_query": terms, "max_results": String(max(1, min(limit, 10))), "sortBy": "relevance",
        ]) else { return [] }
        let page = try await WebFetcher(timeout: 12, maxBytes: 4 * 1_024 * 1_024, userAgent: userAgent)
            .fetch(url, accept: "application/atom+xml")
        let doc = try XMLDocument(data: page.data, options: [.nodeLoadExternalEntitiesNever])
        let entries = try doc.nodes(forXPath: "//*[local-name()='entry']")
        return entries.enumerated().compactMap { index, entry in
            func value(_ name: String) -> String? {
                (try? entry.nodes(forXPath: "./*[local-name()='\(name)']").first?.stringValue).flatMap { $0 }.map(ContentExtractor.clean)
            }
            guard let title = value("title"), let summary = value("summary"), let link = value("id") else { return nil }
            return SearchHit(source: .arxiv, title: title, url: link, snippet: String(summary.prefix(300)),
                             published: value("published"), blocks: ["# " + title, summary], rank: index)
        }
    }
}

// MARK: - Stack Exchange (Fragen + beste Antworten)

nonisolated struct StackExchangeSource: SearchSource {
    var userAgent: String = SourceHTTP.apiUserAgent
    var sites: [String] = ["stackoverflow"]
    var id: ResearchSource { .stackExchange }

    func search(_ query: String, limit: Int) async throws -> [SearchHit] {
        var all: [SearchHit] = []
        for site in sites.prefix(3) where !site.isEmpty {
            all += (try? await search(query, site: site, limit: limit)) ?? []
        }
        return all.sorted { $0.rank < $1.rank }
    }

    private func search(_ query: String, site: String, limit: Int) async throws -> [SearchHit] {
        guard let url = SourceHTTP.url("https://api.stackexchange.com/2.3/search/advanced", [
            "order": "desc", "sort": "relevance", "q": query, "site": site, "answers": "1",
            "pagesize": String(max(1, min(limit, 10))), "filter": "withbody",
        ]), let json = try await SourceHTTP.json(url, userAgent: userAgent) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else { return [] }

        let questions = items.prefix(4)
        let ids = questions.compactMap { $0["question_id"] as? Int }.map(String.init).joined(separator: ";")
        var answersByQuestion: [Int: [String]] = [:]
        if !ids.isEmpty,
           let answersURL = SourceHTTP.url("https://api.stackexchange.com/2.3/questions/\(ids)/answers", [
               "order": "desc", "sort": "votes", "site": site, "filter": "withbody", "pagesize": "20",
           ]),
           let answersJSON = try? await SourceHTTP.json(answersURL, userAgent: userAgent) as? [String: Any],
           let answers = answersJSON["items"] as? [[String: Any]] {
            for answer in answers {
                guard let qid = answer["question_id"] as? Int, let body = answer["body"] as? String,
                      (answersByQuestion[qid]?.count ?? 0) < 2 else { continue }
                let score = answer["score"] as? Int ?? 0
                let accepted = answer["is_accepted"] as? Bool == true
                let text = ContentExtractor.extractHTML("<html><body>\(body)</body></html>", url: "").blocks
                answersByQuestion[qid, default: []].append(
                    "## Antwort (\(accepted ? "akzeptiert, " : "")\(score) Punkte)\n\n" + text.joined(separator: "\n\n"))
            }
        }

        return questions.enumerated().compactMap { index, item in
            guard let title = item["title"] as? String, let link = item["link"] as? String,
                  let qid = item["question_id"] as? Int else { return nil }
            let cleanTitle = ContentExtractor.clean(CFXMLCreateStringByUnescapingEntities(nil, title as CFString, nil) as String)
            let question = ContentExtractor.extractHTML("<html><body>\(item["body"] as? String ?? "")</body></html>", url: link).blocks
            let blocks = ["# " + cleanTitle] + question.prefix(4) + (answersByQuestion[qid] ?? [])
            return SearchHit(source: .stackExchange, title: cleanTitle, url: link,
                             snippet: String(question.joined(separator: " ").prefix(300)), blocks: blocks, rank: index)
        }
    }
}
