import XCTest
import SwiftUI
@testable import Lernassist

/// Darstellung der Tool-Aufrufe (Phase 6): Live-Code aus unvollständigem JSON, Quellen, Code-Läufe.
final class ToolPresentationTests: XCTestCase {

    // Die Tests prüfen die deutschen Titel; die Oberfläche startet sonst auf Englisch.
    override func setUp() { Loc.current = .german }
    override func tearDown() { Loc.current = .english }

    func testPartialCodeWhileStreaming() {
        let partial = #"{"language":"python","code":"import numpy as np\nx = np.arange(3)\nprint(\"Hal"#
        let p = ToolCallPresentation(call: ToolCallInfo(id: "1", index: 0, name: "coding_sandbox", arguments: partial))
        XCTAssertFalse(p.argumentsComplete)
        XCTAssertEqual(p.code, "import numpy as np\nx = np.arange(3)\nprint(\"Hal")
        XCTAssertEqual(p.language, "python")
        XCTAssertEqual(p.title, "Schreibt Code …")
    }

    func testCompleteArgumentsAndTitles() {
        let call = ToolCallInfo(id: "1", index: 0, name: "web_search", arguments: #"{"query":"Citratzyklus Regulation"}"#)
        XCTAssertEqual(ToolCallPresentation(call: call).title, "Websuche: „Citratzyklus Regulation“")
        let browse = ToolCallInfo(id: "2", index: 0, name: "browse_url", arguments: #"{"url":"https://www.amboss.com/de/wissen/x"}"#)
        XCTAssertEqual(ToolCallPresentation(call: browse).title, "Liest amboss.com")
    }

    func testSourcesFromSearchResult() {
        var call = ToolCallInfo(id: "1", index: 0, name: "web_search", arguments: #"{"query":"x"}"#)
        call.result = """
        <EXTERNAL_CONTENT>
        Belege zu „x“:

        [W1] Citratzyklus — de.wikipedia.org (2024-12-20)
        URL: https://de.wikipedia.org/wiki/Citratzyklus
        Text …

        [W2] Lexikon — spektrum.de
        URL: https://www.spektrum.de/lexikon/x
        Text …
        </EXTERNAL_CONTENT>
        """
        let sources = ToolCallPresentation(call: call).sources
        XCTAssertEqual(sources.map(\.number), ["W1", "W2"])
        XCTAssertEqual(sources.first?.title, "Citratzyklus")
        XCTAssertEqual(sources.last?.domain, "spektrum.de")
    }

    func testCodeRunParsing() {
        var ok = ToolCallInfo(id: "1", index: 0, name: "coding_sandbox", arguments: #"{"language":"python","code":"print(1)"}"#)
        ok.result = "--- AUSGABE (script_v1.py) ---\n1\n\nErkläre dem Nutzer jetzt kurz, was der Code macht."
        let run = ToolCallPresentation(call: ok).codeRun
        XCTAssertEqual(run?.output, "1")
        XCTAssertEqual(run?.exitCode, 0)

        var failed = ToolCallInfo(id: "2", index: 0, name: "coding_sandbox", arguments: #"{"language":"python","code":"1/0"}"#)
        failed.result = "<TOOL_ERROR>\n--- AUSGABE (script_v2.py) ---\nTraceback (most recent call last):\nZeroDivisionError: division by zero\n\nExit Code: 1\n\n--- BETROFFENE CODEZEILEN ---\n→   1 | 1/0\nKorrigiere den Fehler und sende eine vollständige, korrigierte Version an coding_sandbox.\n</TOOL_ERROR>"
        let p = ToolCallPresentation(call: failed)
        XCTAssertTrue(p.isError)
        XCTAssertEqual(p.codeRun?.exitCode, 1)
        XCTAssertTrue(p.codeRun?.output.contains("ZeroDivisionError") == true)
        XCTAssertEqual(p.codeRun?.errorContext, "→   1 | 1/0")
    }

    func testHighlighterColorsPythonKeywordsAndStrings() {
        let attributed = CodeHighlighter.highlight("def f():\n    return \"def\"  # Kommentar", language: "python")
        let runs = attributed.runs.map { (String(attributed[$0.range].characters), $0.swiftUI.foregroundColor) }
        XCTAssertTrue(runs.contains { $0.0 == "def" && $0.1 == CodeHighlighter.Palette.keyword })
        XCTAssertTrue(runs.contains { $0.0 == "\"def\"" && $0.1 == CodeHighlighter.Palette.string }, "Schlüsselwort im String bleibt String")
        XCTAssertTrue(runs.contains { $0.0.hasPrefix("# Kommentar") && $0.1 == CodeHighlighter.Palette.comment })
    }
}

extension ToolPresentationTests {
    func testCitationLinking() {
        let links = ["W1": "https://a.org", "W3": "https://c.org"]
        XCTAssertEqual(ChatViewModel.linkCitations(in: "Fakt [W1].", links: links), "Fakt [W1](https://a.org).")
        XCTAssertEqual(ChatViewModel.linkCitations(in: "Beides [W1, W3]", links: links), "Beides [W1](https://a.org) [W3](https://c.org)")
        XCTAssertEqual(ChatViewModel.linkCitations(in: "Unbekannt [W2]", links: links), "Unbekannt [W2]")
        XCTAssertEqual(ChatViewModel.linkCitations(in: "Schon Link [W1](x)", links: links), "Schon Link [W1](x)")
    }
}
