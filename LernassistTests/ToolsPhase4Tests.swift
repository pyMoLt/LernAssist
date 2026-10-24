import XCTest
@testable import Lernassist

/// Tools (Phase 4): coding_sandbox-Fehlerkontext, quiz_card, recall_screenshot, Slash-Befehle.
@MainActor
final class ToolsPhase4Tests: XCTestCase {

    func testRegistryHasNoTerminalAndStableOrder() {
        let names = ToolRegistry.shared.tools.map(\.name)
        XCTAssertEqual(names, ["web_search", "browse_url", "calculate", "coding_sandbox", "recall_screenshot", "quiz_card"])
    }

    func testSystemPromptDoesNotRepeatToolDescriptions() {
        let addition = ToolRegistry.shared.systemPromptAddition
        for tool in ToolRegistry.shared.enabledTools {
            XCTAssertFalse(addition.contains(tool.description), "Beschreibung von \(tool.name) doppelt im Prompt")
        }
        XCTAssertLessThan(addition.count, 1_800)
    }

    func testCodingErrorContextPointsToModelLine() {
        let code = "import math\nx = 1\ny = x / 0\nprint(y)"
        let line = CodingEnvironment.preludeLineCount + 3
        let traceback = """
        Traceback (most recent call last):
          File "/tmp/CodingOutput/abc/script_v2.py", line \(line), in <module>
        ZeroDivisionError: division by zero
        """
        let context = CodingTool.errorContext(output: traceback, code: code)
        XCTAssertNotNil(context)
        XCTAssertTrue(context!.contains("→   3 | y = x / 0"))
        XCTAssertTrue(context!.contains("    2 | x = 1"))
    }

    func testQuizCardToolValidatesAndBuildsArtifact() async {
        let tool = QuizCardTool()
        let bad = await tool.run(arguments: #"{"question":"Q","options":["nur eine"]}"#, sessionID: nil)
        XCTAssertTrue(bad.isError)

        let good = await tool.run(arguments: #"{"question":"Wo läuft der Citratzyklus?","options":["Zytosol","Mitochondrienmatrix"],"correct_option":2,"explanation":"In der Matrix."}"#, sessionID: nil)
        XCTAssertFalse(good.isError)
        guard case .quiz(let card)? = good.artifacts.first else { return XCTFail("Kein Quiz-Artefakt") }
        XCTAssertEqual(card.correctIndex, 1)
        XCTAssertEqual(card.options.count, 2)
        XCTAssertFalse(card.isAnswered)
    }

    func testQuizAnswerText() {
        let card = QuizCard(question: "Wo?", options: ["A-Text", "B-Text"], correctIndex: 1)
        XCTAssertEqual(ChatViewModel.quizAnswerText(card: card, optionIndex: 1, freeText: nil), "Meine Antwort auf „Wo?“: B) B-Text (richtig)")
        XCTAssertEqual(ChatViewModel.quizAnswerText(card: card, optionIndex: 0, freeText: nil), "Meine Antwort auf „Wo?“: A) A-Text (falsch)")
        XCTAssertEqual(ChatViewModel.quizAnswerText(card: QuizCard(question: "Warum?", options: []), optionIndex: nil, freeText: "Weil."),
                       "Meine Antwort auf „Warum?“: Weil.")
    }

    func testQuizCardSurvivesCodable() throws {
        var message = ChatMessage(role: "assistant", content: "")
        message.quizCard = QuizCard(question: "Q", options: ["a", "b"], correctIndex: 0, selectedIndex: 1)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.quizCard?.selectedIndex, 1)
    }

    func testRecallScreenshot() async {
        let tool = RecallScreenshotTool()
        tool.screenshotProvider = { _ in
            [ChatScreenshot(number: 1, base64: "QQ==", caption: ""), ChatScreenshot(number: 2, base64: "Qg==", caption: ""),
             ChatScreenshot(number: 3, base64: "Qw==", caption: "")]
        }
        let byNumber = await tool.run(arguments: #"{"number":1}"#, sessionID: "s")
        guard case .modelImage(let number)? = byNumber.artifacts.first else { return XCTFail() }
        XCTAssertEqual(number, 1)

        let previous = await tool.run(arguments: "{}", sessionID: "s")
        guard case .modelImage(let prev)? = previous.artifacts.first else { return XCTFail() }
        XCTAssertEqual(prev, 2, "Ohne Nummer: vorletzter Screenshot")

        let missing = await tool.run(arguments: #"{"number":9}"#, sessionID: "s")
        XCTAssertTrue(missing.isError)
    }

    func testScreenshotNumbering() {
        let messages = [ChatMessage(role: "user", content: "a", imageID: UUID()),
                        ChatMessage(role: "assistant", content: "b"),
                        ChatMessage(role: "user", content: "c"),
                        ChatMessage(role: "user", content: "d", imageBase64: "x")]
        let numbers = ChatViewModel.screenshotNumbers(in: messages)
        XCTAssertEqual(numbers[messages[0].id], 1)
        XCTAssertEqual(numbers[messages[3].id], 2)
        XCTAssertNil(numbers[messages[2].id])
    }

    func testLearningStyleAliases() {
        XCTAssertEqual(ChatViewModel.learningStyle(matching: "tutor"), .tutor)
        XCTAssertEqual(ChatViewModel.learningStyle(matching: "Prüfung"), .exam)
        XCTAssertEqual(ChatViewModel.learningStyle(matching: "kurz"), .compact)
        XCTAssertNil(ChatViewModel.learningStyle(matching: "quatsch"))
    }
}
