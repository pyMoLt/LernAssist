import XCTest
@testable import Lernassist

/// Recherche: chatweite Belegnummern, URL-Duplikate, Zähleranzeige und die neuen Quellen.
final class ResearchSourcesTests: XCTestCase {

    private func searchCall(_ id: String, _ sources: [(String, String)]) -> ToolCallInfo {
        var lines = ["Belege zu „x“ (Quellen: SearXNG; sortiert nach Keyword-Relevanz):", ""]
        for (index, source) in sources.enumerated() {
            lines += ["[W\(index + 1)] \(source.0) — example.org", "URL: \(source.1)", "Text \(index + 1)", ""]
        }
        lines.append("Nutze diese Belege …")
        return ToolCallInfo(id: id, index: 0, name: "web_search", arguments: "{}", result: lines.joined(separator: "\n"))
    }

    @MainActor func testCitationsAreNumberedAcrossTheWholeChat() {
        let earlier = searchCall("a", [("Seite A", "https://a.org/1"), ("Seite B", "https://b.org/2")])
        let parallel1 = searchCall("b", [("Seite C", "https://c.org/3"), ("Seite A erneut", "https://www.a.org/1/")])
        let parallel2 = searchCall("c", [("Seite D", "https://d.org/4")])

        let renumbered = ChatViewModel.renumberCitations(in: [parallel1, parallel2], after: [earlier])
        let first = ToolCallPresentation(call: renumbered[0]).sources
        let second = ToolCallPresentation(call: renumbered[1]).sources
        XCTAssertEqual(first.map(\.number), ["W3", "W1"], "Neue Seite zählt weiter, bekannte Seite behält ihre Nummer")
        XCTAssertEqual(second.map(\.number), ["W4"], "Parallele Suchen in Aufruf-Reihenfolge")
        XCTAssertTrue(renumbered[0].result?.contains("Text 1") == true)
    }

    func testWikipediaUrlVariantsShareOneKey() {
        XCTAssertEqual(SearchHit.normalizedKey("https://de.wikipedia.org/wiki/Landtagswahl_in_Sachsen-Anhalt_2026"),
                       SearchHit.normalizedKey("https://de.m.wikipedia.org/wiki/Landtagswahl%20in%20Sachsen-Anhalt%202026#Termin"))
        XCTAssertNotEqual(SearchHit.normalizedKey("https://a.org/x"), SearchHit.normalizedKey("https://a.org/y"))
    }

    @MainActor func testUsageBadgeNumbersStayShort() {
        XCTAssertEqual(UsageBadge.compact(7), "7")
        XCTAssertEqual(UsageBadge.compact(999), "999")
        XCTAssertEqual(UsageBadge.compact(1_000), "1k")
        XCTAssertEqual(UsageBadge.compact(1_234), "1,2k")
        XCTAssertEqual(UsageBadge.compact(12_345), "12k")
        XCTAssertEqual(UsageBadge.compact(2_500_000), "2,5M")
    }

    @MainActor func testUsageCountersResetPerDayAndMonth() {
        let store = ResearchUsageStore.shared
        let calendar = Calendar.current
        let base = calendar.date(from: DateComponents(year: 2031, month: 3, day: 30, hour: 12))!
        let nextDay = calendar.date(byAdding: .day, value: 1, to: base)!
        let nextMonth = calendar.date(byAdding: .day, value: 3, to: base)!
        store.record(.openAlex, now: base)
        store.record(.openAlex, now: base)
        XCTAssertEqual(store.today(.openAlex, now: base), 2)
        store.record(.openAlex, now: nextDay)
        XCTAssertEqual(store.today(.openAlex, now: nextDay), 1)
        XCTAssertEqual(store.thisMonth(.openAlex, now: nextDay), 3)
        store.record(.openAlex, error: "HTTP 429", now: nextMonth)
        XCTAssertEqual(store.thisMonth(.openAlex, now: nextMonth), 1)
        XCTAssertEqual(store.entry(.openAlex)?.lastError, "HTTP 429")
    }

    func testOpenAlexAbstractFromInvertedIndex() {
        let text = OpenAlexSource.abstract(from: ["Die": [0], "Niere": [1, 4], "filtert": [2], "Blut;": [3]])
        XCTAssertEqual(text, "Die Niere filtert Blut; Niere")
    }

    func testOpenFDAUsesSingleWordsAsDrugNames() {
        XCTAssertEqual(OpenFDASource.candidateNames(in: "Metformin Dosierung bei GFR 30"), ["Metformin", "Dosierung"])
        let label: [String: Any] = [
            "set_id": "abc", "openfda": ["generic_name": ["METFORMIN"], "brand_name": ["Glucophage"]],
            "dosage_and_administration": ["Start with 500 mg twice daily."],
            "contraindications": ["Severe renal impairment (eGFR below 30)."],
        ]
        let hit = OpenFDASource.hit(from: label, rank: 0)
        XCTAssertEqual(hit?.url, "https://dailymed.nlm.nih.gov/dailymed/lookup.cfm?setid=abc")
        XCTAssertTrue(hit?.blocks?.contains("## Dosierung und Anwendung") == true)
    }

    func testEveryHostHasPoliteSpacing() {
        XCTAssertEqual(HostPacing.spacing(for: "export.arxiv.org"), 3.0)
        XCTAssertEqual(HostPacing.spacing(for: "de.wikipedia.org"), 0.5)
        XCTAssertGreaterThanOrEqual(HostPacing.spacing(for: "irgendeine-seite.de"), 1.0)
    }
}
