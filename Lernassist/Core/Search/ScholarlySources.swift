import Foundation

// Zusätzliche, standardmäßig ausgeschaltete Fachquellen. Alle laufen über den WebFetcher
// (SSRF-Sperre, Größenlimit, Abstand pro Host) und bekommen die anonyme App-Kennung – die
// Kontakt-E-Mail geht nur an Wikipedia, Europe PMC, arXiv und Stack Exchange.

// MARK: - OpenAlex (Arbeiten aller Fächer)

nonisolated struct OpenAlexSource: SearchSource {
    var id: ResearchSource { .openAlex }

    func search(_ query: String, limit: Int) async throws -> [SearchHit] {
        guard let url = SourceHTTP.url("https://api.openalex.org/works", [
            "search": query, "per-page": String(max(1, min(limit, 10))), "filter": "has_abstract:true",
        ]), let json = try await SourceHTTP.json(url) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }

        return results.enumerated().compactMap { index, item in
            guard let title = item["display_name"] as? String ?? item["title"] as? String,
                  let inverted = item["abstract_inverted_index"] as? [String: [Int]] else { return nil }
            let abstract = Self.abstract(from: inverted)
            guard !abstract.isEmpty else { return nil }
            let landing = ((item["primary_location"] as? [String: Any])?["landing_page_url"] as? String)
            let link = (item["doi"] as? String) ?? landing ?? (item["id"] as? String) ?? ""
            guard !link.isEmpty else { return nil }
            let venue = (((item["primary_location"] as? [String: Any])?["source"] as? [String: Any])?["display_name"] as? String)
            var blocks = ["# " + ContentExtractor.clean(title)]
            if let venue { blocks.append("Quelle: \(venue)") }
            blocks.append(abstract)
            return SearchHit(source: .openAlex, title: ContentExtractor.clean(title), url: link,
                             snippet: String(abstract.prefix(300)), published: item["publication_date"] as? String,
                             blocks: blocks, rank: index)
        }
    }

    /// OpenAlex liefert Abstracts als „invertierten Index“ (Wort → Positionen).
    static func abstract(from inverted: [String: [Int]]) -> String {
        var words: [Int: String] = [:]
        for (word, positions) in inverted {
            for position in positions { words[position] = word }
        }
        return words.keys.sorted().compactMap { words[$0] }.joined(separator: " ")
    }
}

// MARK: - Semantic Scholar (Abstracts + Kurzfassung)

nonisolated struct SemanticScholarSource: SearchSource {
    var id: ResearchSource { .semanticScholar }

    func search(_ query: String, limit: Int) async throws -> [SearchHit] {
        guard let url = SourceHTTP.url("https://api.semanticscholar.org/graph/v1/paper/search", [
            "query": query, "limit": String(max(1, min(limit, 10))),
            "fields": "title,abstract,url,publicationDate,year,tldr,venue",
        ]), let json = try await SourceHTTP.json(url) as? [String: Any],
              let papers = json["data"] as? [[String: Any]] else { return [] }

        return papers.enumerated().compactMap { index, paper in
            guard let title = paper["title"] as? String, let link = paper["url"] as? String else { return nil }
            let abstract = (paper["abstract"] as? String) ?? ""
            let tldr = (paper["tldr"] as? [String: Any])?["text"] as? String
            guard !abstract.isEmpty || tldr?.isEmpty == false else { return nil }
            var blocks = ["# " + ContentExtractor.clean(title)]
            if let venue = paper["venue"] as? String, !venue.isEmpty { blocks.append("Quelle: \(venue)") }
            if let tldr, !tldr.isEmpty { blocks.append("Kurzfassung: \(tldr)") }
            if !abstract.isEmpty { blocks.append(ContentExtractor.clean(abstract)) }
            let published = (paper["publicationDate"] as? String) ?? (paper["year"] as? Int).map(String.init)
            return SearchHit(source: .semanticScholar, title: ContentExtractor.clean(title), url: link,
                             snippet: String((tldr ?? abstract).prefix(300)), published: published,
                             blocks: blocks, rank: index)
        }
    }
}

// MARK: - MedlinePlus (Gesundheitsthemen)

nonisolated struct MedlinePlusSource: SearchSource {
    var id: ResearchSource { .medlinePlus }

    func search(_ query: String, limit: Int) async throws -> [SearchHit] {
        guard let url = SourceHTTP.url("https://wsearch.nlm.nih.gov/ws/query", [
            "db": "healthTopics", "term": query, "retmax": String(max(1, min(limit, 10))),
        ]) else { return [] }
        let page = try await WebFetcher(timeout: 12, maxBytes: 4 * 1_024 * 1_024, userAgent: SourceHTTP.apiUserAgent)
            .fetch(url, accept: "application/xml,text/xml")
        let doc = try XMLDocument(data: page.data, options: [.nodeLoadExternalEntitiesNever])
        let documents = try doc.nodes(forXPath: "//document")
        return documents.enumerated().compactMap { index, node in
            guard let element = node as? XMLElement,
                  let link = element.attribute(forName: "url")?.stringValue else { return nil }
            func content(_ name: String) -> String? {
                (try? element.nodes(forXPath: "./content[@name='\(name)']").first?.stringValue).flatMap { $0 }
            }
            let title = ContentExtractor.clean((content("title") ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            guard !title.isEmpty, let summary = content("FullSummary"), !summary.isEmpty else { return nil }
            let blocks = ContentExtractor.extractHTML("<html><body>\(summary)</body></html>", url: link).blocks
            guard !blocks.isEmpty else { return nil }
            return SearchHit(source: .medlinePlus, title: title, url: link,
                             snippet: String(blocks.joined(separator: " ").prefix(300)),
                             blocks: ["# " + title] + blocks, rank: index)
        }
    }
}

// MARK: - openFDA (US-Fachinformationen)

nonisolated struct OpenFDASource: SearchSource {
    var id: ResearchSource { .openFDA }

    /// Abschnitte der Fachinformation, die für das Lernen zählen (in dieser Reihenfolge).
    static let sections: [(key: String, title: String)] = [
        ("indications_and_usage", "Anwendungsgebiete"),
        ("dosage_and_administration", "Dosierung und Anwendung"),
        ("contraindications", "Gegenanzeigen"),
        ("warnings_and_cautions", "Warnhinweise"),
        ("warnings", "Warnhinweise"),
        ("adverse_reactions", "Nebenwirkungen"),
        ("drug_interactions", "Wechselwirkungen"),
        ("use_in_specific_populations", "Besondere Patientengruppen"),
        ("mechanism_of_action", "Wirkmechanismus"),
    ]

    func search(_ query: String, limit: Int) async throws -> [SearchHit] {
        // Die Suchanfrage ist meist ein Satz („Metformin Dosierung Niereninsuffizienz“), openFDA
        // sucht aber nach Wirkstoff- oder Handelsnamen. Darum die Wörter einzeln als Namen prüfen.
        for name in Self.candidateNames(in: query).prefix(3) {
            guard let url = SourceHTTP.url("https://api.fda.gov/drug/label.json", [
                "search": "openfda.generic_name:\"\(name)\"+openfda.brand_name:\"\(name)\"",
                "limit": "8",
            ]) else { continue }
            guard let json = try? await SourceHTTP.json(url) as? [String: Any],
                  let results = json["results"] as? [[String: Any]], !results.isEmpty else { continue }
            // Reine Wirkstoff-Präparate vor Kombinationen („Metformin“ vor „Sitagliptin und Metformin“).
            let ranked = results.enumerated().sorted { a, b in
                let exactA = Self.isExactMatch(a.element, name), exactB = Self.isExactMatch(b.element, name)
                return exactA != exactB ? exactA : a.offset < b.offset
            }.map(\.element)
            return ranked.prefix(max(1, min(limit, 3))).enumerated().compactMap { index, label in Self.hit(from: label, rank: index) }
        }
        return []
    }

    static func isExactMatch(_ label: [String: Any], _ name: String) -> Bool {
        let openfda = label["openfda"] as? [String: Any] ?? [:]
        let names = ((openfda["generic_name"] as? [String]) ?? []) + ((openfda["brand_name"] as? [String]) ?? [])
        let wanted = name.lowercased()
        return names.contains { $0.lowercased() == wanted || $0.lowercased() == wanted + " hydrochloride" }
    }

    static func candidateNames(in query: String) -> [String] {
        query.split(whereSeparator: { !$0.isLetter && $0 != "-" })
            .map(String.init)
            .filter { $0.count >= 4 }
    }

    static func hit(from label: [String: Any], rank: Int) -> SearchHit? {
        let openfda = label["openfda"] as? [String: Any] ?? [:]
        let generic = (openfda["generic_name"] as? [String])?.first
        let brand = (openfda["brand_name"] as? [String])?.first
        guard let name = generic ?? brand, let setID = label["set_id"] as? String else { return nil }
        let title = brand.map { "\(name) (\($0)) – US-Fachinformation" } ?? "\(name) – US-Fachinformation"
        var blocks = ["# " + title]
        var seen = Set<String>()
        for section in sections {
            guard let text = (label[section.key] as? [String])?.first, !seen.contains(section.title) else { continue }
            seen.insert(section.title)
            blocks.append("## " + section.title)
            blocks.append(String(ContentExtractor.clean(text).prefix(2_500)))
        }
        guard blocks.count > 1 else { return nil }
        return SearchHit(source: .openFDA, title: title,
                         url: "https://dailymed.nlm.nih.gov/dailymed/lookup.cfm?setid=\(setID)",
                         snippet: String(blocks[min(2, blocks.count - 1)].prefix(300)),
                         published: label["effective_time"] as? String, blocks: blocks, rank: rank)
    }
}

// MARK: - PubMed (NCBI E-Utilities)

/// Fachartikel direkt aus PubMed: ESearch (Treffer-IDs nach Relevanz) und EFetch (Titel, Abstract,
/// Journal, Datum, PMC-Kennung). Ohne Key bis 3 Anfragen pro Sekunde (HostPacing). Anonyme Kennung –
/// die Kontakt-E-Mail geht bewusst nicht an NCBI.
nonisolated struct PubMedSource: SearchSource {
    var id: ResearchSource { .pubmed }
    private static let base = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/"

    func search(_ query: String, limit: Int) async throws -> [SearchHit] {
        let term = ResearchImages.textQuery(query) + " AND hasabstract"
        guard let searchURL = SourceHTTP.url(Self.base + "esearch.fcgi", [
            "db": "pubmed", "term": term, "retmax": String(max(1, min(limit, 10))),
            "sort": "relevance", "retmode": "json", "tool": "LernAssist",
        ]), let json = try await SourceHTTP.json(searchURL) as? [String: Any],
              let ids = (json["esearchresult"] as? [String: Any])?["idlist"] as? [String], !ids.isEmpty else { return [] }

        guard let fetchURL = SourceHTTP.url(Self.base + "efetch.fcgi", [
            "db": "pubmed", "id": ids.joined(separator: ","), "retmode": "xml", "rettype": "abstract", "tool": "LernAssist",
        ]) else { return [] }
        let page = try await WebFetcher(timeout: 12, maxBytes: 4 * 1_024 * 1_024, userAgent: SourceHTTP.apiUserAgent)
            .fetch(fetchURL, accept: "application/xml")
        return try Self.parse(page.data, order: ids)
    }

    /// EFetch-XML → Treffer in der Relevanz-Reihenfolge der Suche.
    static func parse(_ data: Data, order: [String]) throws -> [SearchHit] {
        let doc = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        func text(_ node: XMLNode, _ xpath: String) -> String? {
            (try? node.nodes(forXPath: xpath))?.compactMap(\.stringValue)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        }
        var byID: [String: SearchHit] = [:]
        for article in try doc.nodes(forXPath: "//PubmedArticle") {
            guard let pmid = text(article, "MedlineCitation/PMID"),
                  let rawTitle = text(article, "MedlineCitation/Article/ArticleTitle") else { continue }
            let parts = ((try? article.nodes(forXPath: "MedlineCitation/Article/Abstract/AbstractText")) ?? []).compactMap { node -> String? in
                guard let value = node.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
                if let label = (node as? XMLElement)?.attribute(forName: "Label")?.stringValue, !label.isEmpty {
                    return "\(label.capitalized): \(value)"
                }
                return value
            }
            guard !parts.isEmpty else { continue }
            let title = ContentExtractor.clean(rawTitle)
            let journal = text(article, "MedlineCitation/Article/Journal/Title")
            let year = text(article, "MedlineCitation/Article/Journal/JournalIssue/PubDate/Year")
                ?? text(article, "MedlineCitation/Article/Journal/JournalIssue/PubDate/MedlineDate").map { String($0.prefix(4)) }
            let link = "https://pubmed.ncbi.nlm.nih.gov/\(pmid)/"
            var blocks = ["# " + title]
            if let journal { blocks.append("Journal: \(journal)") }
            blocks += parts
            var hit = SearchHit(source: .pubmed, title: title, url: link, snippet: String(parts.joined(separator: " ").prefix(300)),
                                published: year, blocks: blocks, rank: order.firstIndex(of: pmid) ?? order.count)
            // Freie Volltexte in PubMed Central: Abbildungen samt Legende von der PMC-Artikelseite.
            if let pmc = text(article, "PubmedData/ArticleIdList/ArticleId[@IdType='pmc']") {
                hit.figurePage = "https://pmc.ncbi.nlm.nih.gov/articles/\(pmc)/"
            }
            byID[pmid] = hit
        }
        return order.compactMap { byID[$0] }
    }
}
