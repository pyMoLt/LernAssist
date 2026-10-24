import XCTest
import JavaScriptCore
@testable import Lernassist

/// Auto-Korrekturen für Modellausgaben (Version 4): Tool-Argumente, Python-Code und LaTeX-Formeln.
final class AutoRepairTests: XCTestCase {

    private func object(_ text: String?) -> [String: Any]? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func testValidJSONStaysUnchanged() {
        let json = #"{"code": "print(1)", "language": "python"}"#
        XCTAssertEqual(ToolArgumentRepair.repair(json), json)
    }

    func testCommonModelMistakesAreRepaired() {
        XCTAssertEqual(object(ToolArgumentRepair.repair(#"{"query": "ATP", "deep": True,}"#))?["deep"] as? Bool, true)
        XCTAssertEqual(object(ToolArgumentRepair.repair("```json\n{\"query\": \"x\"}\n```"))?["query"] as? String, "x")
        XCTAssertEqual(object(ToolArgumentRepair.repair("{'query': 'Niere', 'max': None}"))?["query"] as? String, "Niere")
        let rawNewline = "{\"code\": \"print(1)\nprint(2)\", \"language\": \"python\"}"
        XCTAssertEqual(object(ToolArgumentRepair.repair(rawNewline))?["code"] as? String, "print(1)\nprint(2)")
    }

    func testTruncatedJSONIsClosed() {
        let truncated = #"{"language": "html", "code": "<html><body>Hallo"#
        XCTAssertEqual(object(ToolArgumentRepair.repair(truncated))?["code"] as? String, "<html><body>Hallo")
        XCTAssertNotNil(object(ToolArgumentRepair.repair(#"{"options": ["a", "b""#)))
    }

    func testTrueInsideStringsIsKept() {
        let json = "{'text': 'True story', 'flag': False}"
        let parsed = object(ToolArgumentRepair.repair(json))
        XCTAssertEqual(parsed?["text"] as? String, "True story")
        XCTAssertEqual(parsed?["flag"] as? Bool, false)
    }

    func testPythonRepairsKeepLineCount() {
        let code = "import numpy as np\n%matplotlib inline\nfor i in range(3):\n\tprint(i)\n    x\u{00A0}= 1\n!pip install seaborn"
        let fixed = CodingEnvironment.repairCommonMistakes(code)
        XCTAssertEqual(fixed.components(separatedBy: "\n").count, code.components(separatedBy: "\n").count)
        XCTAssertTrue(fixed.contains("pass  # (von LernAssist entfernt: %matplotlib inline)"))
        XCTAssertTrue(fixed.contains("    print(i)"), "Tabs bei gemischter Einrückung zu Leerzeichen")
        XCTAssertFalse(fixed.contains("\u{00A0}"))
        XCTAssertTrue(fixed.hasSuffix("pass  # (von LernAssist entfernt: !pip install seaborn)"))
    }

    func testLatexMathAutoRepairInIndexHTML() throws {
        let htmlURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Lernassist/Resources/index.html")
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        guard let start = html.range(of: "function expandCe(math)"),
              let end = html.range(of: "function restoreMath(html, store)") else {
            XCTFail("Mathe-Reparaturfunktionen in index.html nicht gefunden")
            return
        }
        let jsCode = String(html[start.lowerBound..<end.lowerBound])
        let ctx = JSContext()!
        ctx.evaluateScript(jsCode)

        let preprocess = ctx.objectForKeyedSubscript("preprocessLatexMath")!
        let fixedGibbs = preprocess.call(withArguments: [#"\text{ATP} \rightarrow \text{ADP} + \text{P}_i \quad \Delta G^\circ' \approx -30.5 \text{ kJ/mol}"#])!.toString()!
        XCTAssertTrue(fixedGibbs.contains(#"\Delta G^{\circ \prime}"#), "Doppel-Superskript \\Delta G^\\circ' muss zu^{\\circ \\prime} repariert werden: \(fixedGibbs)")

        let fixedCe = preprocess.call(withArguments: [#"\ce{ATP + H2O -> ADP + P_i}"#])!.toString()!
        XCTAssertFalse(fixedCe.contains(#"\ce{"#))
        XCTAssertTrue(fixedCe.contains(#"\mathrm{"#) && fixedCe.contains(#"\rightarrow"#) && fixedCe.contains("H_{2}O"))

        let fixedPercent = preprocess.call(withArguments: [#"\eta = 45%"#])!.toString()!
        XCTAssertEqual(fixedPercent, #"\eta = 45\%"#)

        let repairBare = ctx.objectForKeyedSubscript("repairBareMathLines")!
        let bareLine = "Die Reaktion lautet:\n\\text{ATP} \\rightarrow \\text{ADP} + \\text{P}_i \\quad \\Delta G^\\circ' \\approx -30.5 \\text{ kJ/mol}\nWeiter im Text."
        let wrapped = repairBare.call(withArguments: [bareLine])!.toString()!
        XCTAssertTrue(wrapped.contains("$$\\text{ATP} \\rightarrow \\text{ADP} + \\text{P}_i \\quad \\Delta G^\\circ' \\approx -30.5 \\text{ kJ/mol}$$"))
    }
}
