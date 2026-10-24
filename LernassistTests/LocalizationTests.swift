import XCTest
@testable import Lernassist

/// Zweisprachige Oberfläche (Version 4): Englisch als Standard, Deutsch als zweite Sprache.
final class LocalizationTests: XCTestCase {
    override func tearDown() { Loc.current = .english }

    func testEnglishIsDefaultAndTranslatesWithPlaceholders() {
        Loc.current = .english
        XCTAssertEqual(L("Neuer Chat"), "New Chat")
        let count = 3
        XCTAssertEqual(L("\(count) Quellen"), "3 sources")
        XCTAssertEqual(L("Letzter Fehler \("gestern"): \("Timeout")"), "Last error gestern: Timeout")
    }

    func testGermanShowsSourceText() {
        Loc.current = .german
        XCTAssertEqual(L("Neuer Chat"), "Neuer Chat")
        XCTAssertEqual(L("\(2) Quellen"), "2 Quellen")
    }

    func testUnknownTextFallsBackToGerman() {
        Loc.current = .english
        XCTAssertEqual(L("Gibt es nicht in der Tabelle"), "Gibt es nicht in der Tabelle")
        XCTAssertEqual(L(dynamic: "Tutor (Schrittweise anleiten)"), "Tutor (step-by-step guidance)")
    }

    func testPlaceholderCountsMatch() {
        // Jede Übersetzung hat genauso viele Platzhalter wie ihr deutscher Schlüssel.
        for (german, english) in EnglishStrings.table {
            XCTAssertEqual(german.components(separatedBy: "%@").count, english.components(separatedBy: "%@").count, german)
        }
    }
}
