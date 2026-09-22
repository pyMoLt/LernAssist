//
//  LernassistTests.swift
//  LernassistTests
//
//  Created by LernAssist on 17.04.26.
//

import XCTest
@testable import Lernassist

final class LernassistTests: XCTestCase {
    func testInlineExplanationFollowUpDoesNotRepeatCurrentQuestion() {
        let previousQuestion = ChatMessage(role: "user", content: "Was ist Photosynthese?")
        let previousAnswer = ChatMessage(role: "assistant", content: "Die Umwandlung von Licht in Energie.")
        let currentQuestion = ChatMessage(role: "user", content: "Und welche Rolle spielt Chlorophyll?")
        let pendingAnswer = ChatMessage(role: "assistant", content: "")

        let history = InlineExplainPopover.historyForFollowUp(
            [previousQuestion, previousAnswer, currentQuestion, pendingAnswer],
            excludingCurrentQuestion: currentQuestion.id,
            pendingAssistantMessage: pendingAnswer.id
        )

        XCTAssertEqual(history.map(\.id), [previousQuestion.id, previousAnswer.id])
        XCTAssertFalse(history.contains(where: { $0.id == currentQuestion.id }))
    }

    func testChatMessageEqualityIncludesImageContextFreezeState() {
        let id = UUID()
        let unfrozen = ChatMessage(id: id, role: "user", content: "Bild", isImageContextFrozen: false)
        let frozen = ChatMessage(id: id, role: "user", content: "Bild", isImageContextFrozen: true)

        XCTAssertNotEqual(unfrozen, frozen)
    }

    func testSearchRankingKeepsRelevantResultBeyondInitialProviderHits() {
        let genericTrump = SearchResult(
            title: "Donald Trump – Wikipedia",
            url: "https://en.wikipedia.org/wiki/Donald_Trump",
            snippet: "",
            providerScore: 1
        )
        let unrelated = SearchResult(
            title: "Aktuelle Schlagzeilen",
            url: "https://example.com/news",
            snippet: "Nachrichten aus aller Welt.",
            providerScore: 0.9
        )
        let cabinet = SearchResult(
            title: "Donald J. Trump Cabinet Nominations – Senate.gov",
            url: "https://www.senate.gov/legislative/nominations/Trump_47_cabinet.htm",
            snippet: "Confirmed members of the second Trump administration cabinet in 2025.",
            providerScore: 0.5
        )

        let ranked = SearchService.rankResults(
            [genericTrump, unrelated, cabinet],
            for: "Donald Trump second term cabinet list 2025 members confirmed"
        )

        XCTAssertEqual(ranked.first?.url, cabinet.url)
        XCTAssertFalse(ranked.contains(where: { $0.url == unrelated.url }))
    }

    func testRestoredSessionMarksInterruptedToolCallAsFinished() {
        let pending = ToolCallInfo(
            id: "call_pending",
            index: nil,
            name: "web_search",
            arguments: "{\"query\":\"Berlin Wetter\"}",
            result: nil,
            source: nil
        )
        var session = ChatSession(
            title: "Unterbrochene Recherche",
            messages: [ChatMessage(role: "assistant", content: "", toolCalls: [pending])]
        )

        XCTAssertTrue(SessionStore.resolveInterruptedToolCalls(in: &session))
        XCTAssertEqual(
            session.messages[0].toolCalls?[0].result,
            "Unterbrochen: Die App wurde beendet, bevor dieser Tool-Aufruf abgeschlossen war."
        )
    }

    func testMissingToolCallIDsBecomeStableAndMatchResultReferences() {
        let messageID = UUID()
        let calls = [
            ToolCallInfo(id: "", index: 0, name: "web_search", arguments: "{\"query\":\"Berlin Wetter\"}"),
            ToolCallInfo(id: "", index: 1, name: "browse_url", arguments: "{\"url\":\"https://example.com\"}")
        ]

        let normalized = ChatViewModel.normalizedToolCalls(calls, messageID: messageID)

        XCTAssertEqual(normalized.map(\.id), ChatViewModel.normalizedToolCalls(calls, messageID: messageID).map(\.id))
        XCTAssertTrue(normalized.allSatisfy { !$0.id.isEmpty })
        XCTAssertEqual(Set(normalized.map(\.id)).count, calls.count)
    }

    func testToolFailureExplicitlyTellsTheModelToCorrectItsCall() {
        let result = ToolResult.failure("Fehler: Ungültige Tool-Argumente – erwartet: {\"query\": \"...\"}.")

        XCTAssertTrue(result.formatted.contains("<TOOL_ERROR>"))
        XCTAssertTrue(result.formatted.contains("korrigiere die Argumente"))
    }

    func testOllamaToolHistoryUsesNativeArgumentsAndToolNamesForParallelCalls() {
        let messages: [[String: Any]] = [
            ["role": "assistant", "content": NSNull(), "tool_calls": [
                ["id": "call_search", "type": "function", "function": ["name": "web_search", "arguments": "{\"query\":\"Berlin Wetter\"}"]],
                ["id": "call_calc", "type": "function", "function": ["name": "calculate", "arguments": "{\"expression\":\"2+2\"}"]]
            ]],
            ["role": "tool", "tool_call_id": "call_search", "content": "Ergebnis A"],
            ["role": "tool", "tool_call_id": "call_calc", "content": "4"]
        ]

        let converted = EndpointManager.ollamaMessages(from: messages)
        let calls = converted[0]["tool_calls"] as? [[String: Any]]
        let firstFunction = calls?[0]["function"] as? [String: Any]

        XCTAssertEqual(firstFunction?["arguments"] as? [String: String], ["query": "Berlin Wetter"])
        XCTAssertEqual(converted[1]["tool_name"] as? String, "web_search")
        XCTAssertEqual(converted[2]["tool_name"] as? String, "calculate")
        XCTAssertNil(converted[1]["tool_call_id"])
    }

    func testEditingBranchPrunesSelectedQuestionAndKeepsEarlierContext() {
        let earlierQuestion = ChatMessage(role: "user", content: "Erste Frage")
        let earlierAnswer = ChatMessage(role: "assistant", content: "Erste Antwort")
        let questionToEdit = ChatMessage(role: "user", content: "Diese Frage ändern")
        let laterAnswer = ChatMessage(role: "assistant", content: "Nicht im Zweig")

        let plan = ChatViewModel.editingBranchPlan(
            for: [earlierQuestion, earlierAnswer, questionToEdit, laterAnswer],
            userMessageID: questionToEdit.id
        )

        XCTAssertEqual(plan?.history.map(\.id), [earlierQuestion.id, earlierAnswer.id])
        XCTAssertEqual(plan?.draft, questionToEdit.content)
    }
}
