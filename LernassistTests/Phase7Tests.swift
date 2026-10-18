import XCTest
@testable import Lernassist

/// UI-Logik ohne Oberfläche: Arbeitsschritte, Antwort-Blöcke, Sandbox-Pfade, Code-Präsentation.
final class Phase7Tests: XCTestCase {
    private func tool(_ name: String, _ args: String = "{}", result: String? = "ok") -> ToolCallInfo {
        ToolCallInfo(id: UUID().uuidString, index: 0, name: name, arguments: args, result: result, source: nil)
    }

    func testStepsKeepOrderThinkingNoteTools() {
        let first = ChatMessage(role: "assistant", content: "Ich suche kurz.", thinking: "Was weiß ich?",
                                toolCalls: [tool("web_search", #"{"query":"Koffein"}"#)])
        let second = ChatMessage(role: "assistant", content: "Antwort", thinking: "Jetzt rechnen")
        let steps = WorkStep.steps(from: [first, second])
        XCTAssertEqual(steps.count, 4)
        guard case .thinking = steps[0].kind, case .note(let note) = steps[1].kind,
              case .tool(let call) = steps[2].kind, case .thinking = steps[3].kind else {
            return XCTFail("Reihenfolge falsch: \(steps.map(\.kind))")
        }
        XCTAssertEqual(note, "Ich suche kurz.")
        XCTAssertEqual(call.name, "web_search")
    }

    func testLongTextBeforeToolIsAnswerNotNote() {
        let long = String(repeating: "Erklärung mit Details. ", count: 20)
        let message = ChatMessage(role: "assistant", content: long, toolCalls: [tool("coding_sandbox")])
        XCTAssertTrue(WorkStep.hasAnswerText(message))
        XCTAssertFalse(WorkStep.steps(from: [message]).contains { if case .note = $0.kind { return true } else { return false } })

        let short = ChatMessage(role: "assistant", content: "Ich rechne nach.", toolCalls: [tool("calculate")])
        XCTAssertFalse(WorkStep.hasAnswerText(short))
        XCTAssertTrue(WorkStep.hasAnswerText(ChatMessage(role: "assistant", content: "Fertig.")))
        XCTAssertFalse(WorkStep.hasAnswerText(ChatMessage(role: "assistant", content: "  ")))
    }

    func testRowItemsGroupConsecutiveAssistantMessages() {
        let user = ChatMessage(role: "user", content: "Frage")
        let a1 = ChatMessage(role: "assistant", content: "", toolCalls: [tool("web_search")])
        let a2 = ChatMessage(role: "assistant", content: "Antwort")
        let user2 = ChatMessage(role: "user", content: "Danke")
        let a3 = ChatMessage(role: "assistant", content: "Gern")
        let items = ChatRowItem.items(from: [user, a1, a2, user2, a3])
        XCTAssertEqual(items.count, 4)
        guard case .turn(let turn) = items[1] else { return XCTFail() }
        XCTAssertEqual(turn.map(\.id), [a1.id, a2.id])
        XCTAssertEqual(items[1].id, a1.id, "Stabile Identität = erste Nachricht der Antwort")
        guard case .turn(let last) = items[3] else { return XCTFail() }
        XCTAssertEqual(last.count, 1)
    }

    func testSandboxPathVariantsCoverPrivatePrefix() {
        XCTAssertEqual(Set(CodingEnvironment.pathVariants("/private/tmp/x/python3")), ["/private/tmp/x/python3", "/tmp/x/python3"])
        XCTAssertEqual(Set(CodingEnvironment.pathVariants("/tmp/x/python3")), ["/tmp/x/python3", "/private/tmp/x/python3"])
        XCTAssertEqual(CodingEnvironment.pathVariants("/Users/a/python3"), ["/Users/a/python3"])
    }

    func testPresentationParsesArgumentsOnceAndStreamsPartialCode() {
        let complete = ToolCallPresentation(call: tool("coding_sandbox", #"{"language":"python","code":"print(1)\nprint(2)"}"#, result: nil))
        XCTAssertTrue(complete.argumentsComplete)
        XCTAssertEqual(complete.code, "print(1)\nprint(2)")
        let partial = ToolCallPresentation(call: tool("coding_sandbox", #"{"language":"python","code":"import numpy as np\nx = "#, result: nil))
        XCTAssertFalse(partial.argumentsComplete)
        XCTAssertEqual(partial.code, "import numpy as np\nx = ")
        XCTAssertEqual(partial.language, "python")
    }

    func testHighlighterCacheReturnsSameResult() {
        let code = "def f(x):\n    return x * 2  # doppelt"
        let a = CodeHighlighter.highlight(code, language: "python")
        let b = CodeHighlighter.highlight(code, language: "python")
        XCTAssertEqual(a, b)
        XCTAssertEqual(String(a.characters), code)
    }
}
