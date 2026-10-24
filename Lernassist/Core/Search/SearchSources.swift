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
    /// Abbildungen der Seite (Kandidaten für [B#]).
    var images: [PageImage]? = nil
    /// Seite mit Abbildungen samt Legende (Europe PMC → PMC-Artikel), geladen nur wenn zitiert.
    var figurePage: String? = nil

    var domain: String { URL(string: url)?.host?.lowercased().replacingOccurrences(of: "www.", with: "") ?? "" }

    /// Normalisierte URL für die Duplikaterkennung.
    var key: String { Self.normalizedKey(url) }

    /// Gleiche Seite → gleicher Schlüssel: ohne www/Mobil-Präfix, Fragment und Tracking-Parameter,
    /// Pfad dekodiert (Prozent-Kodierung, bei Wikipedia Leerzeichen = Unterstrich).
    static func normalizedKey(_ url: String) -> String {
        guard var c = URLComponents(string: url) else { return url.lowercased() }
        c.scheme = "https"
        let host = c.host?.lowercased().replacingOccurrences(of: "www.", with: "").replacingOccurrences(of: ".m.wikipedia.org", with: ".wikipedia.org")
        c.host = host
        c.fragment = nil
        c.queryItems = c.queryItems?.filter { !$0.name.lowercased().hasPrefix("utm_") && $0.name != "ref" }
        if c.queryItems?.isEmpty == true { c.queryItems = nil }
        var path = c.path.removingPercentEncoding ?? c.path
        if host?.hasSuffix("wikipedia.org") == true { path = path.replacingOccurrences(of: " ", with: "_") }
        while path.hasSuffix("/") { path.removeLast() }
        let query = c.percentEncodedQuery.map { "?" + $0 } ?? ""
        return ("https://" + (host ?? "") + path + query).lowercased()
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

    static func json(_ url: URL, userAgent: String = apiUserAgent, timeout: TimeInterval = 12, headers: [String: String] = [:]) async throws -> Any {
        // APIs bekommen eine ehrliche App-Kennung (optional mit Kontakt-E-Mail, siehe
        // ResearchSettings.apiContactEmail).
        let fetcher = WebFetcher(timeout: timeout, maxBytes: 4 * 1_024 * 1_024, userAgent: userAgent)
        let page = try await fetcher.fetch(url, accept: "application/json", headers: headers)
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
    var timeout: TimeInterval = 70
    var headers: [String: String] = [:]
    var id: ResearchSource { .searxng }

    func search(_ query: String, limit: Int) async throws -> [SearchHit] {
        let results = try await SearchService.shared.search(query: query, baseURL: baseURL, limit: limit, timeout: timeout,
                                                            headers: headers)
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
    /// Abbildungen der Top-Artikel mitladen (Einstellung „Abbildungen aus der Recherche“).
    var withImages: Bool = true
    var id: ResearchSource { .wikipedia }

    func search(_ query: String, limit: Int) async throws -> [SearchHit] {
        let lang = language.isEmpty ? "de" : language
        guard let url = SourceHTTP.url("https://\(lang).wikipedia.org/w/rest.php/v1/search/page",
                                       ["q": ResearchImages.textQuery(query), "limit": String(max(1, min(limit, 10)))]),
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
        await withTaskGroup(of: (Int, [String]?, [PageImage]).self) { group in
            for index in hits.indices.prefix(fullArticles) {
                let title = hits[index].title
                let pageURL = hits[index].url
                group.addTask {
                    async let blocks = try? Self.article(title: title, lang: lang, userAgent: userAgent)
                    async let images = withImages
                        ? Self.mediaImages(title: title, lang: lang, pageURL: pageURL, userAgent: userAgent) : []
                    return (index, await blocks, await images)
                }
            }
            for await (index, blocks, images) in group {
                if blocks?.isEmpty == false { hits[index].blocks = blocks }
                if !images.isEmpty { hits[index].images = images }
            }
        }
        return hits
    }

    /// Abbildungen eines Artikels über die Medien-Schnittstelle (mit Bildunterschriften).
    static func mediaImages(title: String, lang: String, pageURL: String,
                            userAgent: String = SourceHTTP.apiUserAgent) async -> [PageImage] {
        let path = title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? title
        guard let url = URL(string: "https://\(lang).wikipedia.org/api/rest_v1/page/media-list/\(path)"),
              let json = try? await SourceHTTP.json(url, userAgent: userAgent) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item -> PageImage? in
            guard item["type"] as? String == "image", item["showInGallery"] as? Bool != false,
                  let srcset = item["srcset"] as? [[String: Any]] else { return nil }
            let sources = srcset.compactMap { $0["src"] as? String }
            // Vorschaubilder (…/thumb/…) statt Originale: kleiner und auch für SVG als PNG gerendert.
            guard let src = sources.last(where: { $0.contains("/thumb/") }) ?? sources.first else { return nil }
            let caption = ContentExtractor.clean(((item["caption"] as? [String: Any])?["text"] as? String) ?? "")
            return PageImage(url: src.hasPrefix("//") ? "https:" + src : src, pageURL: pageURL,
                             caption: String(caption.prefix(300)), alt: "")
        }
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
            "query": ResearchImages.textQuery(query) + " AND HAS_ABSTRACT:y", "format": "json", "resultType": "core",
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
            let pmcid = (item["isOpenAccess"] as? String == "Y") ? item["pmcid"] as? String : nil
            let abstractBlocks = ContentExtractor.extractHTML("<html><body><p>\(abstract)</p></body></html>", url: link).blocks
            let cleanTitle = ContentExtractor.clean(title.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            var blocks = ["# " + cleanTitle]
            if let journal { blocks.append("Journal: \(journal)") }
            blocks += abstractBlocks
            var hit = SearchHit(source: .europePMC, title: cleanTitle, url: link,
                                snippet: String(abstract.prefix(300)), published: item["firstPublicationDate"] as? String ?? item["pubYear"] as? String,
                                blocks: blocks, rank: index)
            // Merker für die Abbildungen (Open Access): die PMC-Artikelseite.
            if let pmcid { hit.figurePage = "https://pmc.ncbi.nlm.nih.gov/articles/\(pmcid)/" }
            return hit
        }
    }

    /// Abbildungen samt Legende aus der PMC-Artikelseite (nur Open Access).
    static func figures(articlePage: String) async -> [PageImage] {
        guard let url = URL(string: articlePage),
              let page = try? await WebFetcher(timeout: 15, maxBytes: 6 * 1_048_576).fetch(url) else { return [] }
        let document = ContentExtractor.extractHTML(ContentExtractor.decode(page.data, encodingName: page.textEncodingName),
                                                    url: articlePage)
        return document.images.filter { !$0.caption.isEmpty }
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
        // Stack Exchange verlangt per `backoff` (Sekunden) eine Pause – sonst droht eine Sperre.
        if let backoff = json["backoff"] as? Int { await HostPacing.shared.pause(host: "api.stackexchange.com", seconds: TimeInterval(backoff)) }

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
