import Foundation

/// Datenquellen der Websuche. Jede ist einzeln schaltbar.
nonisolated enum ResearchSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case searxng
    case wikipedia
    case europePMC = "europepmc"
    case arxiv
    case stackExchange = "stackexchange"
    case openAlex = "openalex"
    case semanticScholar = "semanticscholar"
    case medlinePlus = "medlineplus"
    case openFDA = "openfda"
    /// Exa über MCP – nur Fallback, wenn die anderen Quellen zu wenig liefern.
    case exa

    var id: String { rawValue }

    var label: String {
        switch self {
        case .searxng:       return "SearXNG (Websuche)"
        case .wikipedia:     return "Wikipedia"
        case .europePMC:     return "Europe PMC (Medizin/Biologie)"
        case .arxiv:         return "arXiv (Naturwissenschaft/Technik)"
        case .stackExchange: return "Stack Exchange"
        case .openAlex:      return "OpenAlex (Fachliteratur aller Fächer)"
        case .semanticScholar: return "Semantic Scholar (Fachliteratur)"
        case .medlinePlus:   return "MedlinePlus (Gesundheitsthemen, Englisch)"
        case .openFDA:       return "openFDA (US-Fachinformationen zu Arzneimitteln)"
        case .exa:           return "Exa (Fallback über MCP)"
        }
    }

    var systemImage: String {
        switch self {
        case .searxng:       return "magnifyingglass"
        case .wikipedia:     return "book.closed"
        case .europePMC:     return "cross.case"
        case .arxiv:         return "atom"
        case .stackExchange: return "bubble.left.and.text.bubble.right"
        case .openAlex:      return "books.vertical"
        case .semanticScholar: return "graduationcap"
        case .medlinePlus:   return "heart.text.square"
        case .openFDA:       return "pills"
        case .exa:           return "sparkle.magnifyingglass"
        }
    }

    var help: String {
        switch self {
        case .searxng:       return "Allgemeine Websuche über eine eigene SearXNG-Instanz."
        case .wikipedia:     return "Artikel direkt über die Wikipedia-API – sauberer Text ohne Seitenmenüs."
        case .europePMC:     return "Fachartikel mit Abstracts aus Europe PMC (enthält PubMed)."
        case .arxiv:         return "Preprints aus Physik, Mathematik, Informatik, Biologie."
        case .stackExchange: return "Beste Antworten von Stack Overflow und anderen Stack-Exchange-Seiten. Ohne Key etwa 300 Anfragen pro Tag."
        case .openAlex:      return "Offener Katalog wissenschaftlicher Arbeiten aller Fächer, mit Abstracts. Kostenlos, ohne Key."
        case .semanticScholar: return "Fachartikel mit Abstracts und Kurzfassungen. Ohne Key gemeinsamer, knapper Zugang – kann langsam sein."
        case .medlinePlus:   return "Verständliche Übersichten zu Krankheiten und Gesundheitsthemen der US-Nationalbibliothek (Englisch)."
        case .openFDA:       return "Amerikanische Fachinformationen (Indikation, Dosierung, Kontraindikationen) zu einem Wirkstoff. Für deutsche Präparate gibt es keine freie Schnittstelle."
        case .exa:           return "KI-aufbereitete Websuche von Exa. Wird nur gefragt, wenn die anderen Quellen zu wenig liefern. Ohne Key: kostenlose Stufe."
        }
    }
}

/// Reranker-Modus für das Absatz-Ranking.
nonisolated enum RerankerMode: String, Codable, CaseIterable, Sendable {
    /// Nur Keyword-Relevanz (BM25).
    case off
    /// Reranker nutzen, wenn erreichbar – bei Fehler oder Timeout BM25-Reihenfolge.
    case auto

    var label: String {
        switch self {
        case .off:  return "Aus (nur Keyword-Relevanz)"
        case .auto: return "An (bei Fehler Keyword-Relevanz)"
        }
    }
}

/// Alle Einstellungen der Websuche. Als ein Codable-Block in settings.json gespeichert –
/// neue Felder brauchen nur einen Default in `init(from:)`.
nonisolated struct ResearchSettings: Codable, Equatable, Sendable {
    var enabledSources: Set<ResearchSource> = [.searxng, .wikipedia, .europePMC, .arxiv, .stackExchange, .exa]

    // Treffer & Volltexte
    var resultsPerSource: Int = 6
    var fullTextPages: Int = 3
    var fetchTimeout: Double = 15
    var maxDownloadMB: Double = 10

    // Absätze
    var passageChars: Int = 600
    var maxPassages: Int = 8
    var maxPassagesPerSource: Int = 2
    /// Ungefähres Token-Budget der Belege, die an das Modell zurückgehen.
    var tokenBudget: Int = 2_500

    // Reranker
    var rerankerMode: RerankerMode = .auto
    var rerankerModel: String = "Qwen3-Reranker-0.6B-8bit-mlx"
    /// oMLX-Profil, über das gerankt wird (nil = aktives Profil, falls oMLX, sonst erstes oMLX-Profil).
    var rerankerProfileID: UUID? = nil
    var rerankerTimeout: Double = 8
    /// Kandidaten-Fenster für den Reranker (Top-N BM25 an Reranker übergeben).
    var rerankerWindow: Int = 60

    // Quellen-Details
    var wikipediaLanguage: String = "de"
    var stackExchangeSites: [String] = ["stackoverflow"]
    /// Exa wird gefragt, wenn weniger als so viele Webquellen (SearXNG) Treffer liefern.
    var exaMinWebResults: Int = 3
    var exaResults: Int = 5

    // Domains
    var trustedDomains: [String] = ResearchSettings.defaultTrustedDomains
    var goodDomains: [String] = ResearchSettings.defaultGoodDomains
    var blockedDomains: [String] = ["pinterest.com", "facebook.com", "instagram.com", "tiktok.com", "quora.com"]

    var cacheMinutes: Int = 10
    /// Abbildungen aus der Recherche anbieten ([B#], die App zeigt sie im Chat).
    var imagesEnabled: Bool = true
    /// Kontakt (E-Mail) für die App-Kennung bei Fach-APIs (Wikipedia, Europe PMC, arXiv,
    /// Stack Exchange). Wikimedia empfiehlt das ausdrücklich; leer = anonyme Kennung.
    var apiContactEmail: String = ""

    /// User-Agent für API-Quellen.
    var apiUserAgent: String {
        let contact = apiContactEmail.trimmingCharacters(in: .whitespaces)
        return contact.isEmpty ? SourceHTTP.apiUserAgent : "LernAssist/2.0 (macOS learning app; \(contact))"
    }

    init() {}

    static let defaultTrustedDomains = [
        "awmf.org", "register.awmf.org", "leitlinien.de", "pubmed.ncbi.nlm.nih.gov", "ncbi.nlm.nih.gov",
        "europepmc.org", "cochrane.org", "cochranelibrary.com", "rki.de", "who.int", "gesund.bund.de",
        "aerzteblatt.de", "amboss.com", "msdmanuals.com",
    ]
    static let defaultGoodDomains = [
        "thieme-connect.de", "springer.com", "link.springer.com", "springermedizin.de", "flexikon.doccheck.com",
        "de.wikipedia.org", "en.wikipedia.org", "arxiv.org", "mathworld.wolfram.com", "math.stackexchange.com",
        "physics.stackexchange.com", "stackoverflow.com", "docs.python.org", "developer.mozilla.org", "britannica.com",
        "spektrum.de", "lecturio.de", "studyflix.de",
    ]

    enum DomainTier { case trusted, good, neutral, blocked }

    func tier(of domain: String) -> DomainTier {
        let d = domain.lowercased()
        func matches(_ list: [String]) -> Bool { list.contains { d == $0 || d.hasSuffix("." + $0) } }
        if matches(blockedDomains) { return .blocked }
        if matches(trustedDomains) { return .trusted }
        if matches(goodDomains) { return .good }
        return .neutral
    }

    func tierBonus(of domain: String) -> Double {
        switch tier(of: domain) {
        case .trusted: return 0.15
        case .good:    return 0.05
        default:       return 0
        }
    }

    // Codable mit Defaults für fehlende Felder
    private enum CodingKeys: String, CodingKey {
        case enabledSources, resultsPerSource, fullTextPages, fetchTimeout, maxDownloadMB
        case passageChars, maxPassages, maxPassagesPerSource, tokenBudget
        case rerankerMode, rerankerModel, rerankerProfileID, rerankerTimeout, rerankerWindow
        case wikipediaLanguage, stackExchangeSites, exaMinWebResults, exaResults
        case trustedDomains, goodDomains, blockedDomains, cacheMinutes, apiContactEmail, imagesEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ResearchSettings()
        // Unbekannte (künftige/entfernte) Quellen beim Laden ignorieren statt den Block zu verwerfen.
        let rawSources = try c.decodeIfPresent([String].self, forKey: .enabledSources)
        enabledSources = rawSources.map { Set($0.compactMap(ResearchSource.init(rawValue:))) } ?? d.enabledSources
        resultsPerSource = try c.decodeIfPresent(Int.self, forKey: .resultsPerSource) ?? d.resultsPerSource
        fullTextPages = try c.decodeIfPresent(Int.self, forKey: .fullTextPages) ?? d.fullTextPages
        fetchTimeout = try c.decodeIfPresent(Double.self, forKey: .fetchTimeout) ?? d.fetchTimeout
        maxDownloadMB = try c.decodeIfPresent(Double.self, forKey: .maxDownloadMB) ?? d.maxDownloadMB
        passageChars = try c.decodeIfPresent(Int.self, forKey: .passageChars) ?? d.passageChars
        maxPassages = try c.decodeIfPresent(Int.self, forKey: .maxPassages) ?? d.maxPassages
        maxPassagesPerSource = try c.decodeIfPresent(Int.self, forKey: .maxPassagesPerSource) ?? d.maxPassagesPerSource
        tokenBudget = try c.decodeIfPresent(Int.self, forKey: .tokenBudget) ?? d.tokenBudget
        rerankerMode = try c.decodeIfPresent(RerankerMode.self, forKey: .rerankerMode) ?? d.rerankerMode
        rerankerModel = try c.decodeIfPresent(String.self, forKey: .rerankerModel) ?? d.rerankerModel
        rerankerProfileID = try c.decodeIfPresent(UUID.self, forKey: .rerankerProfileID)
        rerankerTimeout = try c.decodeIfPresent(Double.self, forKey: .rerankerTimeout) ?? d.rerankerTimeout
        rerankerWindow = try c.decodeIfPresent(Int.self, forKey: .rerankerWindow) ?? d.rerankerWindow
        wikipediaLanguage = try c.decodeIfPresent(String.self, forKey: .wikipediaLanguage) ?? d.wikipediaLanguage
        stackExchangeSites = try c.decodeIfPresent([String].self, forKey: .stackExchangeSites) ?? d.stackExchangeSites
        exaMinWebResults = try c.decodeIfPresent(Int.self, forKey: .exaMinWebResults) ?? d.exaMinWebResults
        exaResults = try c.decodeIfPresent(Int.self, forKey: .exaResults) ?? d.exaResults
        trustedDomains = try c.decodeIfPresent([String].self, forKey: .trustedDomains) ?? d.trustedDomains
        goodDomains = try c.decodeIfPresent([String].self, forKey: .goodDomains) ?? d.goodDomains
        blockedDomains = try c.decodeIfPresent([String].self, forKey: .blockedDomains) ?? d.blockedDomains
        cacheMinutes = try c.decodeIfPresent(Int.self, forKey: .cacheMinutes) ?? d.cacheMinutes
        imagesEnabled = try c.decodeIfPresent(Bool.self, forKey: .imagesEnabled) ?? true
        apiContactEmail = try c.decodeIfPresent(String.self, forKey: .apiContactEmail) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabledSources.map(\.rawValue).sorted(), forKey: .enabledSources)
        try c.encode(resultsPerSource, forKey: .resultsPerSource)
        try c.encode(fullTextPages, forKey: .fullTextPages)
        try c.encode(fetchTimeout, forKey: .fetchTimeout)
        try c.encode(maxDownloadMB, forKey: .maxDownloadMB)
        try c.encode(passageChars, forKey: .passageChars)
        try c.encode(maxPassages, forKey: .maxPassages)
        try c.encode(maxPassagesPerSource, forKey: .maxPassagesPerSource)
        try c.encode(tokenBudget, forKey: .tokenBudget)
        try c.encode(rerankerMode, forKey: .rerankerMode)
        try c.encode(rerankerModel, forKey: .rerankerModel)
        try c.encodeIfPresent(rerankerProfileID, forKey: .rerankerProfileID)
        try c.encode(rerankerTimeout, forKey: .rerankerTimeout)
        try c.encode(rerankerWindow, forKey: .rerankerWindow)
        try c.encode(wikipediaLanguage, forKey: .wikipediaLanguage)
        try c.encode(stackExchangeSites, forKey: .stackExchangeSites)
        try c.encode(exaMinWebResults, forKey: .exaMinWebResults)
        try c.encode(exaResults, forKey: .exaResults)
        try c.encode(trustedDomains, forKey: .trustedDomains)
        try c.encode(goodDomains, forKey: .goodDomains)
        try c.encode(blockedDomains, forKey: .blockedDomains)
        try c.encode(cacheMinutes, forKey: .cacheMinutes)
        try c.encode(imagesEnabled, forKey: .imagesEnabled)
        try c.encode(apiContactEmail, forKey: .apiContactEmail)
    }
}
