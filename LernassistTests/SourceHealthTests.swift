import XCTest
@testable import Lernassist

/// Zuverlässigere Websuche (Version 4.0): Quellen-Zustand, Zeitbudget, PubMed, Umstellung der Quellen.
final class SourceHealthTests: XCTestCase {

    private struct FakeSource: SearchSource {
        let id: ResearchSource
        var delay: TimeInterval = 0
        var error: Error? = nil
        func search(_ query: String, limit: Int) async throws -> [SearchHit] {
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            if let error { throw error }
            return [SearchHit(source: id, title: "\(id.rawValue) Glykolyse", url: "https://example.org/\(id.rawValue)",
                              snippet: "Die Glykolyse läuft im Zytosol ab.", blocks: ["Die Glykolyse läuft im Zytosol ab und liefert Pyruvat."], rank: 0)]
        }
    }

    private func pipeline(_ sources: [SearchSource], budget: Double = 30, earlyFinish: Int = 0, health: SourceHealth) -> WebResearchPipeline {
        var settings = ResearchSettings()
        settings.sourceBudgetSeconds = budget
        settings.earlyFinishHits = earlyFinish
        settings.imagesEnabled = false
        settings.rerankerMode = .off
        settings.enabledSources = Set(sources.map(\.id))
        var p = WebResearchPipeline(settings: settings, searxngURL: "")
        p.sourceOverride = sources
        p.healthOverride = health
        return p
    }

    func testClassification() {
        XCTAssertEqual(SourceHealth.classify(WebFetchError.rateLimited(429, nil)), .rateLimit)
        XCTAssertEqual(SourceHealth.classify(WebFetchError.httpStatus(503)), .outage)
        XCTAssertEqual(SourceHealth.classify(WebFetchError.httpStatus(429)), .rateLimit)
        XCTAssertEqual(SourceHealth.classify(SearchService.SearchError.rateLimited(429, 5)), .rateLimit)
        XCTAssertNil(SourceHealth.classify(SearchService.SearchError.noResults), "0 Treffer sind kein Fehler")
        XCTAssertEqual(SourceHealth.classify(URLError(.timedOut)), .outage)
        XCTAssertEqual(SourceHealth.classify(NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "Daily quota exceeded"])), .rateLimit)
    }

    func testRateLimitPausesAtOnceOutagePausesAfterTwo() async {
        let health = SourceHealth()
        let paused = await health.recordFailure(.pubmed, kind: .rateLimit, pauseMinutes: 4)
        XCTAssertTrue(paused)
        let pause = await health.pause(for: .pubmed)
        XCTAssertEqual(pause?.reason, .rateLimit)

        let first = await health.recordFailure(.arxiv, kind: .outage, pauseMinutes: 4)
        XCTAssertFalse(first)
        let notYet = await health.pause(for: .arxiv)
        XCTAssertNil(notYet)
        let second = await health.recordFailure(.arxiv, kind: .outage, pauseMinutes: 4)
        XCTAssertTrue(second)

        // Erfolg dazwischen setzt den Zähler zurück.
        _ = await health.recordFailure(.wikipedia, kind: .outage, pauseMinutes: 4)
        await health.recordSuccess(.wikipedia)
        let afterSuccess = await health.recordFailure(.wikipedia, kind: .outage, pauseMinutes: 4)
        XCTAssertFalse(afterSuccess)

        await health.resume(.pubmed)
        let resumed = await health.pause(for: .pubmed)
        XCTAssertNil(resumed)
    }

    func testPausedSourceIsSkippedWithoutRequest() async {
        let health = SourceHealth()
        _ = await health.recordFailure(.europePMC, kind: .rateLimit, pauseMinutes: 4)
        let result = await pipeline([FakeSource(id: .wikipedia), FakeSource(id: .europePMC, delay: 20)], health: health)
            .run("Glykolyse Zytosol")
        XCTAssertEqual(result.statuses.first { $0.source == .europePMC }?.state, .paused)
        XCTAssertEqual(result.statuses.first { $0.source == .wikipedia }?.state, .ok)
        XCTAssertFalse(result.passages.isEmpty)
    }

    func testBudgetSkipsSlowSource() async {
        let health = SourceHealth()
        let start = Date()
        let result = await pipeline([FakeSource(id: .wikipedia), FakeSource(id: .arxiv, delay: 30)], budget: 5, health: health)
            .run("Glykolyse Zytosol")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 9, "Die Suche wartet höchstens das Zeitbudget ab")
        XCTAssertEqual(result.statuses.first { $0.source == .arxiv }?.state, .timeout)
        XCTAssertFalse(result.passages.isEmpty)
    }

    func testOutageSkipsQuickly() async {
        let health = SourceHealth()
        let result = await pipeline([FakeSource(id: .wikipedia), FakeSource(id: .pubmed, error: WebFetchError.httpStatus(503))], health: health)
            .run("Glykolyse Zytosol")
        XCTAssertEqual(result.statuses.first { $0.source == .pubmed }?.state, .failed)
        let notPaused = await health.pause(for: .pubmed)
        XCTAssertNil(notPaused, "Ein einzelner Ausfall pausiert nicht")
    }

    func testOldSettingsSwitchToPubMed() throws {
        let old = #"{"enabledSources": ["arxiv", "europepmc", "searxng", "wikipedia"]}"#
        let settings = try JSONDecoder().decode(ResearchSettings.self, from: Data(old.utf8))
        XCTAssertTrue(settings.enabledSources.contains(.pubmed))
        XCTAssertFalse(settings.enabledSources.contains(.europePMC))
        // Danach bleibt eine bewusste Wahl erhalten.
        var chosen = settings
        chosen.enabledSources.insert(.europePMC)
        let roundTrip = try JSONDecoder().decode(ResearchSettings.self, from: JSONEncoder().encode(chosen))
        XCTAssertTrue(roundTrip.enabledSources.contains(.europePMC))
        XCTAssertEqual(roundTrip.sourceBudgetSeconds, 30)
        XCTAssertEqual(roundTrip.sourcePauseMinutes, 4)
        XCTAssertEqual(roundTrip.searxngTimeout, 70)
    }

    func testPubMedParsing() throws {
        let xml = """
        <?xml version="1.0"?>
        <PubmedArticleSet>
          <PubmedArticle>
            <MedlineCitation><PMID>111</PMID><Article>
              <Journal><Title>Kidney Int</Title><JournalIssue><PubDate><Year>2024</Year></PubDate></JournalIssue></Journal>
              <ArticleTitle>Regulation of GFR</ArticleTitle>
              <Abstract><AbstractText Label="BACKGROUND">GFR is regulated.</AbstractText><AbstractText Label="RESULTS">Tubuloglomerular feedback.</AbstractText></Abstract>
            </Article></MedlineCitation>
            <PubmedData><ArticleIdList><ArticleId IdType="pubmed">111</ArticleId><ArticleId IdType="pmc">PMC999</ArticleId></ArticleIdList></PubmedData>
          </PubmedArticle>
          <PubmedArticle>
            <MedlineCitation><PMID>222</PMID><Article><ArticleTitle>No abstract</ArticleTitle></Article></MedlineCitation>
          </PubmedArticle>
        </PubmedArticleSet>
        """
        let hits = try PubMedSource.parse(Data(xml.utf8), order: ["222", "111"])
        XCTAssertEqual(hits.count, 1, "Artikel ohne Abstract fallen weg")
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.url, "https://pubmed.ncbi.nlm.nih.gov/111/")
        XCTAssertEqual(hit.published, "2024")
        XCTAssertEqual(hit.figurePage, "https://pmc.ncbi.nlm.nih.gov/articles/PMC999/")
        XCTAssertTrue(hit.blocks?.contains("Background: GFR is regulated.") == true)
        XCTAssertEqual(hit.rank, 1)
    }

    private struct ManyHitsSource: SearchSource {
        let id: ResearchSource
        func search(_ query: String, limit: Int) async throws -> [SearchHit] {
            (0..<8).map { i in
                SearchHit(source: id, title: "\(id.rawValue) \(i) Glykolyse", url: "https://example.org/\(id.rawValue)/\(i)",
                          snippet: "Die Glykolyse läuft im Zytosol ab.", blocks: ["Die Glykolyse läuft im Zytosol ab und liefert Pyruvat."], rank: i)
            }
        }
    }

    func testEarlyFinishSkipsStragglerWithoutCountingFailure() async {
        let health = SourceHealth()
        let p = pipeline([ManyHitsSource(id: .wikipedia), ManyHitsSource(id: .pubmed), FakeSource(id: .searxng, delay: 25)],
                         budget: 30, earlyFinish: 12, health: health)
        let start = Date()
        let result = await p.run("Glykolyse Zytosol")
        XCTAssertLessThan(Date().timeIntervalSince(start), 8, "Nach genug Treffern nur noch kurze Gnadenfrist")
        XCTAssertEqual(result.statuses.first { $0.source == .searxng }?.state, .skipped)
        XCTAssertEqual(result.statuses.first { $0.source == .wikipedia }?.hits, 8)
        XCTAssertTrue(result.phases.contains { $0.phase == .sources })
        let pause = await health.pause(for: .searxng)
        XCTAssertNil(pause)
        _ = await p.run("Glykolyse Zytosol")
        let stillNoPause = await health.pause(for: .searxng)
        XCTAssertNil(stillNoPause, "Übersprungene Nachzügler zählen nicht als Ausfall")
    }

    func testConnectionFailureIsReportedAsUnreachable() async {
        let health = SourceHealth()
        let result = await pipeline([FakeSource(id: .wikipedia), FakeSource(id: .searxng, error: URLError(.cannotConnectToHost))], health: health)
            .run("Glykolyse Zytosol")
        let status = result.statuses.first { $0.source == .searxng }
        XCTAssertEqual(status?.state, .unreachable)
        let text = SourceStatusLine.describe(status!).lowercased()
        XCTAssertTrue(text.contains("einstellungen") || text.contains("settings"), "Hinweis auf die Adresse in den Einstellungen")
    }
}
