import XCTest
@testable import Lernassist

/// Tests der Websuche (Phase 3): Sperren, Extraktion, Ranking, Quellen-Parser, Pipeline.
final class ResearchTests: XCTestCase {

    // MARK: SSRF-Sperre

    func testPrivateAddressesAreBlocked() {
        for ip in ["127.0.0.1", "10.0.0.5", "172.16.3.1", "192.168.1.1", "169.254.1.1", "100.64.0.1",
                   "0.0.0.0", "::1", "fd7a:115c:a1e0::1", "fe80::1", "::ffff:192.168.0.1"] {
            XCTAssertEqual(IPAddress(ip)?.isPrivate, true, ip)
        }
        for ip in ["8.8.8.8", "142.250.185.78", "2a00:1450:4001:80b::200e", "100.128.0.1"] {
            XCTAssertEqual(IPAddress(ip)?.isPrivate, false, ip)
        }
    }

    func testBlockedHostnames() {
        XCTAssertTrue(WebFetcher.isBlockedHostname("localhost"))
        XCTAssertTrue(WebFetcher.isBlockedHostname("home-server"))
        XCTAssertTrue(WebFetcher.isBlockedHostname("home-server.tail1234.ts.net"))
        XCTAssertTrue(WebFetcher.isBlockedHostname("drucker.local"))
        XCTAssertFalse(WebFetcher.isBlockedHostname("de.wikipedia.org"))
    }

    func testValidateRejectsLocalAndNonHTTP() async {
        for raw in ["http://127.0.0.1:1234/v1/models", "file:///etc/passwd", "http://user:pw@example.com", "http://[::1]:8072/health"] {
            do {
                try await WebFetcher.validate(URL(string: raw)!)
                XCTFail("Sollte gesperrt sein: \(raw)")
            } catch {}
        }
    }

    // MARK: Extraktion

    private let articleHTML = """
    <!doctype html><html><head><title>Citratzyklus – Lexikon</title>
    <meta property="article:published_time" content="2025-04-02T10:00:00Z">
    <script>var tracking = "geheim";</script><style>.x{}</style></head>
    <body>
      <nav><ul><li><a href="/">Start</a></li><li><a href="/a">Anatomie</a></li></ul></nav>
      <div class="cookie-banner">Wir verwenden Cookies. Akzeptieren?</div>
      <article>
        <h1>Citratzyklus</h1>
        <p>Der Citratzyklus ist ein Kreislauf biochemischer Reaktionen im Mitochondrium, der Acetyl-CoA zu CO2 oxidiert.</p>
        <h2>Regulation</h2>
        <p>Die Isocitrat-Dehydrogenase ist ein zentrales Schrittmacherenzym und wird durch ADP aktiviert und durch NADH gehemmt.</p>
        <ul><li>Citrat-Synthase</li><li>Isocitrat-Dehydrogenase</li></ul>
        <table><tr><th>Enzym</th><th>Produkt</th></tr><tr><td>Aconitase</td><td>Isocitrat</td></tr></table>
      </article>
      <aside class="related">Ähnliche Artikel: Glykolyse, Atmungskette, Harnstoffzyklus und vieles mehr.</aside>
      <footer>Impressum · Datenschutz</footer>
    </body></html>
    """

    func testHTMLExtractionKeepsOnlyMainText() {
        let doc = ContentExtractor.extractHTML(articleHTML, url: "https://example.org/citrat")
        let text = doc.text
        XCTAssertEqual(doc.title, "Citratzyklus – Lexikon")
        XCTAssertEqual(doc.published, "2025-04-02T10:00:00Z")
        XCTAssertTrue(text.contains("# Citratzyklus"))
        XCTAssertTrue(text.contains("## Regulation"))
        XCTAssertTrue(text.contains("Isocitrat-Dehydrogenase ist ein zentrales Schrittmacherenzym"))
        XCTAssertTrue(text.contains("• Citrat-Synthase"))
        XCTAssertTrue(text.contains("Aconitase | Isocitrat"))
        for junk in ["tracking", "geheim", "Cookies", "Impressum", "Anatomie", "Ähnliche Artikel", ".x{}"] {
            XCTAssertFalse(text.contains(junk), "Boilerplate im Text: \(junk)")
        }
    }

    func testUTF8IsDecodedCorrectly() {
        let page = FetchedPage(url: URL(string: "https://e.org")!, mimeType: "text/html", textEncodingName: nil,
                               data: Data("<html><body><p>Glukose-6-phosphat wird über Pyruvat zu Acetyl-CoA – größere Moleküle.</p></body></html>".utf8),
                               wasTruncated: false)
        let doc = try? ContentExtractor.extract(page)
        XCTAssertTrue(doc?.text.contains("größere Moleküle") == true)
    }

    func testBotPageDetection() {
        XCTAssertTrue(ContentExtractor.looksLikeBotPage(ExtractedDocument(title: "Just a moment...", url: "", blocks: ["Checking your browser before accessing."])))
        XCTAssertFalse(ContentExtractor.looksLikeBotPage(ExtractedDocument(title: "", url: "", blocks: [String(repeating: "Inhalt ", count: 100)])))
    }

    // MARK: Ranking

    func testStemmingMatchesInflections() {
        XCTAssertEqual(PassageRanker.stem("mitochondrien"), PassageRanker.stem("mitochondrium"))
        XCTAssertEqual(PassageRanker.tokens("Die Enzyme der Glykolyse"), PassageRanker.tokens("enzymes glykolyse"))
    }

    func testSplitMergesHeadingIntoNextPiece() {
        let pieces = PassageRanker.split(["## Regulation", String(repeating: "Ein Satz über Enzyme. ", count: 60)], target: 300)
        XCTAssertTrue(pieces[0].hasPrefix("## Regulation Ein Satz"))
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 450 })
    }

    func testKeywordListsArePenalized() {
        let list = "subjects: | Biochemie, Vorlesung, Citratzyklus, Aconitase, Isocitrat-Dehydrogenase, Fumarase, Malat-Dehydrogenase, Gluconeogenese, Citratzyklus-Regulation"
        let prose = "Die Isocitrat-Dehydrogenase wird durch ADP aktiviert und durch ATP sowie NADH gehemmt, wodurch der Citratzyklus an den Energiebedarf angepasst wird."
        XCTAssertLessThan(PassageRanker.proseQuality(list), 0.5)
        XCTAssertEqual(PassageRanker.proseQuality(prose), 1)
    }

    func testBM25PrefersRelevantPassage() {
        let docs = [PassageRanker.tokens("Die Atmungskette liegt in der inneren Mitochondrienmembran."),
                    PassageRanker.tokens("Isocitrat-Dehydrogenase wird durch NADH gehemmt und durch ADP aktiviert.")]
        let scores = PassageRanker.bm25(documents: docs, query: PassageRanker.tokens("Hemmung Isocitrat-Dehydrogenase NADH"))
        XCTAssertGreaterThan(scores[1], scores[0])
    }

    // MARK: Parser der Quellen

    func testWikipediaPlainTextBlocksStopAtReferences() {
        let blocks = WikipediaSource.blocks(fromWikiText: "Einleitung.\n\n== Ablauf ==\nSchritt eins.\n=== Detail ===\nMehr.\n== Einzelnachweise ==\nRef 1")
        XCTAssertEqual(blocks, ["Einleitung.", "## Ablauf", "Schritt eins.", "### Detail", "Mehr."])
    }

    func testExaResultParsing() {
        let text = """
        Title: Citratzyklus
        URL: https://de.wikipedia.org/wiki/Citratzyklus
        Published: 2026-10-01T12:20:28.000Z
        Author: N/A
        Highlights:
        Der Citratzyklus ist ein Kreislauf biochemischer Reaktionen.
        ...
        Er findet in der Matrix der Mitochondrien statt.

        ---

        Title: Tricarbonsäure-Zyklus
        URL: https://www.spektrum.de/lexikon/biochemie/tricarbonsaeure-zyklus/6188
        Published: N/A
        Author: N/A
        Highlights:
        Zentraler Stoffwechselweg aller aeroben Organismen.
        """
        let hits = ExaSource.parse(text)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].title, "Citratzyklus")
        XCTAssertEqual(hits[0].published, "2026-10-01T12:20:28.000Z")
        XCTAssertNil(hits[1].published)
        XCTAssertTrue(hits[0].blocks?.contains("Er findet in der Matrix der Mitochondrien statt.") == true)
        XCTAssertEqual(hits[1].domain, "spektrum.de")
    }

    func testRerankResponseParsing() throws {
        let data = Data(#"{"results":[{"index":1,"relevance_score":0.9},{"index":0,"relevance_score":0.2}]}"#.utf8)
        XCTAssertEqual(try OMLXReranker.parse(data, count: 2), [0.2, 0.9])
    }

    func testMCPMessageFromSSE() throws {
        let body = "event: message\ndata: {\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]},\"jsonrpc\":\"2.0\",\"id\":4}\n\n"
        let message = try MCPHTTPClient.message(withID: 4, in: Data(body.utf8), contentType: "text/event-stream")
        let content = (message["result"] as? [String: Any])?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["text"] as? String, "hi")
    }

    func testResearchSettingsIgnoreUnknownSources() throws {
        let json = #"{"enabledSources":["wikipedia","gibtsnicht"],"maxPassages":5,"sourceDefaultsVersion":2}"#
        let settings = try JSONDecoder().decode(ResearchSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.enabledSources, [.wikipedia])
        XCTAssertEqual(settings.maxPassages, 5)
        XCTAssertEqual(settings.passageChars, 600)
    }

    func testDedupKeyNormalizesURLs() {
        let a = SearchHit(source: .searxng, title: "", url: "http://www.Example.org/page/?utm_source=x#top", snippet: "", rank: 0)
        let b = SearchHit(source: .exa, title: "", url: "https://example.org/page", snippet: "", rank: 0)
        XCTAssertEqual(a.key, b.key)
    }

    // MARK: Pipeline

    struct FakeSource: SearchSource {
        let id: ResearchSource
        let hits: [SearchHit]
        func search(_ query: String, limit: Int) async throws -> [SearchHit] { hits }
    }

    struct FailingSource: SearchSource {
        let id: ResearchSource
        func search(_ query: String, limit: Int) async throws -> [SearchHit] { throw URLError(.cannotConnectToHost) }
    }

    struct FakeReranker: Reranker {
        var fail = false
        func scores(query: String, documents: [String]) async throws -> [Double] {
            if fail { throw URLError(.timedOut) }
            return documents.map { $0.contains("Schrittmacher") ? 0.95 : 0.1 }
        }
    }

    private func hit(_ source: ResearchSource, _ url: String, _ blocks: [String]?, snippet: String = "", rank: Int = 0) -> SearchHit {
        SearchHit(source: source, title: "T \(url)", url: url, snippet: snippet, blocks: blocks, rank: rank)
    }

    private func pipeline(_ sources: [SearchSource], reranker: Reranker? = nil, settings: ResearchSettings = ResearchSettings()) -> WebResearchPipeline {
        var p = WebResearchPipeline(settings: settings, searxngURL: "", reranker: reranker)
        p.sourceOverride = sources
        p.fetchDocument = { hit, _ in ["Volltext von \(hit.url): Die Isocitrat-Dehydrogenase ist das Schrittmacherenzym des Citratzyklus."] }
        return p
    }

    func testPipelineRanksPassagesAndNumbersSources() async {
        let sources: [SearchSource] = [
            FakeSource(id: .wikipedia, hits: [hit(.wikipedia, "https://de.wikipedia.org/wiki/Citratzyklus",
                ["Der Citratzyklus läuft im Mitochondrium ab.", "Die Isocitrat-Dehydrogenase ist das Schrittmacherenzym des Citratzyklus und wird durch NADH gehemmt."])]),
            FakeSource(id: .searxng, hits: [hit(.searxng, "https://example.org/a", nil, snippet: "Citratzyklus Enzyme"),
                                            hit(.searxng, "https://pinterest.com/pin", nil, snippet: "Citratzyklus Poster"),
                                            hit(.searxng, "https://example.org/b", nil, snippet: "Citratzyklus Schrittmacherenzym")]),
        ]
        let result = await pipeline(sources).run("Schrittmacherenzym Citratzyklus")
        XCTAssertFalse(result.passages.isEmpty)
        XCTAssertFalse(result.passages.contains { $0.domain.contains("pinterest") }, "Gesperrte Domain")
        XCTAssertTrue(result.modelText.contains("[W1]"))
        let numbers = Dictionary(grouping: result.passages, by: \.url).mapValues { Set($0.map(\.number)) }
        XCTAssertTrue(numbers.values.allSatisfy { $0.count == 1 }, "Eine Quelle = eine Belegnummer")
        XCTAssertTrue(Dictionary(grouping: result.passages, by: \.url).values.allSatisfy { $0.count <= 2 })
    }

    func testRerankerOrderAndFallback() async {
        let sources: [SearchSource] = [FakeSource(id: .wikipedia, hits: [hit(.wikipedia, "https://de.wikipedia.org/wiki/A", [
            "Citratzyklus Überblick: Der Citratzyklus ist ein Kreislauf.",
            "Citratzyklus Regulation: Die Isocitrat-Dehydrogenase ist das Schrittmacherenzym.",
        ])])]
        var settings = ResearchSettings()
        settings.maxPassagesPerSource = 1
        let ranked = await pipeline(sources, reranker: FakeReranker(), settings: settings).run("Citratzyklus")
        XCTAssertTrue(ranked.usedReranker)
        XCTAssertTrue(ranked.passages.first?.text.contains("Schrittmacher") == true)

        let fallback = await pipeline(sources, reranker: FakeReranker(fail: true), settings: settings).run("Citratzyklus")
        XCTAssertFalse(fallback.usedReranker)
        XCTAssertFalse(fallback.passages.isEmpty)
        XCTAssertTrue(fallback.notes.contains { $0.contains("Reranker") })
    }

    func testExaOnlyAsFallback() async {
        let exa = FakeSource(id: .exa, hits: [hit(.exa, "https://exa.example/x", ["Citratzyklus laut Exa."])])
        let manyWeb = (0..<4).map { hit(.searxng, "https://web\($0).org", nil, snippet: "Citratzyklus \($0)", rank: $0) }
        let withWeb = await pipeline([FakeSource(id: .searxng, hits: manyWeb), exa]).run("Citratzyklus")
        XCTAssertFalse(withWeb.consultedSources.contains(.exa))

        let fewWeb = await pipeline([FailingSource(id: .searxng), exa]).run("Citratzyklus")
        XCTAssertTrue(fewWeb.consultedSources.contains(.exa))
        XCTAssertTrue(fewWeb.passages.contains { $0.source == .exa })
    }

    func testNoResultsGivesHonestMessage() async {
        let result = await pipeline([FakeSource(id: .wikipedia, hits: [])]).run("xyzzy")
        XCTAssertTrue(result.passages.isEmpty)
        XCTAssertTrue(result.modelText.contains("keine passenden Belege"))
    }

    func testBraveParseAndFallbackRequiresEnabledPlusKey() async {
        let defaults = ResearchSettings()
        XCTAssertFalse(defaults.enabledSources.contains(.brave), "Brave muss standardmäßig aus sein")

        let sampleJSON: [String: Any] = [
            "web": [
                "results": [
                    [
                        "title": "<strong>Hämoglobin</strong> Absorptionsspektrum",
                        "url": "https://example.org/hemoglobin",
                        "description": "Oxyhämoglobin zeigt zwei charakteristische Banden bei 541 nm und 577 nm.",
                        "page_age": "2025-11-02T10:00:00",
                        "extra_snippets": [
                            "Desoxyhämoglobin besitzt eine einzelne breite Bande bei 555 nm im sichtbaren Bereich.",
                            "Die Soret-Bande liegt für beide Formen zwischen 415 nm und 430 nm."
                        ]
                    ]
                ]
            ]
        ]
        let parsed = BraveSearchSource.parse(sampleJSON)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.source, .brave)
        XCTAssertEqual(parsed.first?.title, "Hämoglobin Absorptionsspektrum")
        XCTAssertEqual(parsed.first?.published, "2025-11-02T10:00:00")
        XCTAssertEqual(parsed.first?.blocks?.count, 4)

        let braveFake = FakeSource(id: .brave, hits: parsed)
        var settings = ResearchSettings()
        settings.enabledSources = [.searxng, .brave]

        // 1. Ohne API-Key wird Brave trotz aktiviertem Toggle NICHT abgefragt
        let withoutKey = await WebResearchPipeline(
            settings: settings, searxngURL: "", reranker: nil, exaAPIKey: "", braveAPIKey: "",
            sourceOverride: [FailingSource(id: .searxng), braveFake]
        ).run("Hämoglobin Banden")
        XCTAssertFalse(withoutKey.consultedSources.contains(.brave))

        // 2. Mit API-Key UND aktiviertem Toggle springt Brave als Fallback ein
        let withKey = await WebResearchPipeline(
            settings: settings, searxngURL: "", reranker: nil, exaAPIKey: "", braveAPIKey: "test-brave-key",
            sourceOverride: [FailingSource(id: .searxng), braveFake]
        ).run("Hämoglobin Banden")
        XCTAssertTrue(withKey.consultedSources.contains(.brave))
        XCTAssertTrue(withKey.passages.contains { $0.source == .brave })
    }
}
