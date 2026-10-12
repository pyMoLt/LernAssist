import XCTest
import Carbon
@testable import Lernassist

/// Regressionstests für die Bugfixes aus Phase 0 (Audit 2026-10-12).
@MainActor
final class Phase0RegressionTests: XCTestCase {

    // MARK: Kontext-Kürzung (Chat-Kern H3)

    private func longText(_ tokens: Int) -> String { String(repeating: "x", count: tokens * 4) }

    func testTrimKeepsSystemPromptAndCurrentQuestionInToolRound() {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "SYSTEM"],
            ["role": "user", "content": longText(3_000)],
            ["role": "assistant", "content": longText(3_000)],
            ["role": "user", "content": "AKTUELLE FRAGE"],
            ["role": "assistant", "content": "", "tool_calls": [["id": "1"]]],
            ["role": "tool", "tool_call_id": "1", "content": longText(500)],
        ]
        let trimmed = ChatViewModel.trimmedToContextBudget(messages, contextWindow: 4_096, maxTokens: 512)

        XCTAssertEqual(trimmed.first?["role"] as? String, "system")
        XCTAssertTrue((trimmed.first?["content"] as? String ?? "").hasPrefix("SYSTEM"))
        XCTAssertTrue(trimmed.contains { ($0["content"] as? String) == "AKTUELLE FRAGE" },
                      "Die aktuelle Frage darf in Tool-Runden nicht weggekürzt werden")
        XCTAssertEqual(trimmed.filter { ($0["role"] as? String) == "system" }.count, 1,
                       "Kein zweiter system-Eintrag mitten im Verlauf (Qwen-Templates)")
        XCTAssertEqual(trimmed.last?["role"] as? String, "tool")
    }

    func testTrimLeavesSmallConversationsUntouched() {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "S"],
            ["role": "user", "content": "Hallo"],
        ]
        let trimmed = ChatViewModel.trimmedToContextBudget(messages, contextWindow: 32_768, maxTokens: 1_024)
        XCTAssertEqual(trimmed.count, 2)
    }

    // MARK: HTML-Artefakt CSP (Services H-1)

    func testCSPGoesIntoRealHeadNotHeader() {
        let html = "<html><body><header>Titel</header><script>fetch('http://127.0.0.1:1234')</script></body></html>"
        let hardened = HTMLArtifactView.hardenedHTML(html)
        let csp = hardened.range(of: "Content-Security-Policy")!
        let header = hardened.range(of: "<header>")!
        XCTAssertLessThan(csp.lowerBound, header.lowerBound)
        XCTAssertTrue(hardened.contains("<html><head><meta"))
    }

    func testCSPInsertedIntoExistingHead() {
        let hardened = HTMLArtifactView.hardenedHTML("<!doctype html><html><head><title>x</title></head><body></body></html>")
        XCTAssertTrue(hardened.contains("<head><meta http-equiv=\"Content-Security-Policy\""))
    }

    func testCSPForFragmentWithoutHtmlTag() {
        let hardened = HTMLArtifactView.hardenedHTML("<header>a</header><canvas></canvas>")
        XCTAssertTrue(hardened.hasPrefix("<head><meta http-equiv=\"Content-Security-Policy\""))
    }

    // MARK: Hotkeys

    func testLegacyHotkeyDefaultsAreMigrated() {
        let stored: [String: Hotkey] = [
            "screenshot": Hotkey(keyCode: 1, modifiers: Int(cmdKey) | Int(shiftKey)),
            "newChat": Hotkey(keyCode: 78, modifiers: Int(cmdKey)),
            "toggleSidebar": Hotkey(keyCode: 38, modifiers: Int(cmdKey)),
            "toggleWindow": Hotkey(keyCode: 37, modifiers: Int(cmdKey) | Int(shiftKey)),
        ]
        let migrated = Hotkey.migratedFromLegacyDefaults(stored)
        XCTAssertEqual(migrated["screenshot"], Hotkey.defaultMap[.screenshot])
        XCTAssertEqual(migrated["newChat"], Hotkey.defaultMap[.newChat])
        XCTAssertEqual(migrated["toggleSidebar"], Hotkey.defaultMap[.toggleSidebar])
        XCTAssertEqual(migrated["toggleWindow"], stored["toggleWindow"], "⌘⇧L bleibt der Hauptworkflow")
    }

    func testCustomHotkeysSurviveMigration() {
        let custom = Hotkey(keyCode: 1, modifiers: Int(optionKey) | Int(cmdKey))
        let migrated = Hotkey.migratedFromLegacyDefaults(["screenshot": custom])
        XCTAssertEqual(migrated["screenshot"], custom)
    }

    func testNewChatDefaultIsLetterN() {
        XCTAssertEqual(Hotkey.defaultMap[.newChat]?.keyCode, 45)
        XCTAssertEqual(Hotkey.defaultMap[.newChat]?.displayString, "⌃⇧N")
    }

    // MARK: Remote-Timeouts (Chat-Kern H6)

    func testRequestTimeoutDefaultsDependOnRemote() {
        var profile = EndpointProfile(name: "t", baseURL: "http://127.0.0.1:8072")
        XCTAssertEqual(profile.effectiveRequestTimeout, 180)
        profile.isRemote = true
        XCTAssertEqual(profile.effectiveRequestTimeout, 300)
        profile.requestTimeout = 900
        XCTAssertEqual(profile.effectiveRequestTimeout, 900)
    }

    func testRequestTimeoutRoundTripsThroughCodable() throws {
        var profile = EndpointProfile(name: "t", baseURL: "http://x")
        profile.requestTimeout = 420
        let decoded = try JSONDecoder().decode(EndpointProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded.requestTimeout, 420)
    }

    // MARK: /compact (Chat-Kern H2)

    func testCompactionTranscriptKeepsNewestWhenOverBudget() {
        let messages = (0..<10).map { ChatMessage(role: $0 % 2 == 0 ? "user" : "assistant", content: "Nachricht \($0) " + String(repeating: "a", count: 100)) }
        let transcript = ChatViewModel.compactionTranscript(of: messages, characterBudget: 400)
        XCTAssertTrue(transcript.contains("Nachricht 9"))
        XCTAssertFalse(transcript.contains("Nachricht 0 "))
    }

    func testCompactionTranscriptMentionsScreenshots() {
        var msg = ChatMessage(role: "user", content: "Was zeigt das?", imageID: UUID())
        msg.frozenImageContext = "Folie zur Glykolyse"
        let transcript = ChatViewModel.compactionTranscript(of: [msg])
        XCTAssertTrue(transcript.contains("[Screenshot: Folie zur Glykolyse]"))
    }

    // MARK: Bilder nach Neustart (Chat-Kern H5)

    func testImagePayloadPrefersInMemoryBase64() {
        let msg = ChatMessage(role: "user", content: "", imageBase64: "QUJD", imageID: UUID())
        XCTAssertEqual(ChatViewModel.imagePayloadBase64(for: msg), "QUJD")
    }

    func testImagePayloadIsNilWithoutImage() {
        XCTAssertNil(ChatViewModel.imagePayloadBase64(for: ChatMessage(role: "user", content: "x")))
    }
}
