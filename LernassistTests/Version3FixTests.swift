import XCTest
import PDFKit
@testable import Lernassist

/// Nachbesserungen nach dem Audit vom 13.10.: Thinking-Anzeige, Preserve Thinking,
/// schnelle Inline-Erklärung, isolierte Testablage.
final class Version3FixTests: XCTestCase {

    // MARK: Thinking-Anzeige (nur Darstellung)

    func testThinkingDisplayStripsMarkdown() {
        let raw = """
        ## Plan
        - **Erstens:** den `Citratzyklus` erklären
        * zweitens *kurz* bleiben
        1. dann [Quelle](https://example.org) nennen

        ---
        Fertig.
        """
        let shown = ThinkingText.display(raw)
        XCTAssertFalse(shown.contains("**"))
        XCTAssertFalse(shown.contains("##"))
        XCTAssertFalse(shown.contains("`"))
        XCTAssertFalse(shown.contains("- "))
        XCTAssertFalse(shown.contains("---"))
        XCTAssertTrue(shown.contains("Erstens: den Citratzyklus erklären"))
        XCTAssertTrue(shown.contains("zweitens kurz bleiben"))
        XCTAssertTrue(shown.contains("dann Quelle nennen"))
        XCTAssertTrue(shown.contains("Fertig."))
    }

    func testThinkingDisplayKeepsMultiplication() {
        XCTAssertEqual(ThinkingText.display("2 * 3 = 6"), "2 * 3 = 6")
    }

    func testLivePreviewStartsAtSentenceBoundary() {
        let raw = String(repeating: "Ein langer vorheriger Gedanke ohne Bedeutung. ", count: 12) + "Jetzt prüfe ich die Michaelis-Konstante"
        let preview = ThinkingText.livePreview(raw)
        XCTAssertLessThanOrEqual(preview.count, 241)
        XCTAssertTrue(preview.hasSuffix("Jetzt prüfe ich die Michaelis-Konstante"))
        XCTAssertFalse(preview.hasPrefix(" "))
    }

    // MARK: Preserve Thinking

    @MainActor
    func testReasoningIsSentUnchangedWhenPreserveThinkingIsOn() {
        let vm = ChatViewModel()
        vm.preserveThinking = true
        let thinking = "- **Schritt 1:** Begriff klären\n- Schritt 2"
        let msg = ChatMessage(role: "assistant", content: "Antwort", thinking: thinking)
        let payload = vm.apiMessages(for: msg, provider: .omlx)
        XCTAssertEqual(payload.first?["reasoning_content"] as? String, thinking, "Original, nicht die bereinigte Anzeige")
        XCTAssertEqual(payload.first?["content"] as? String, "Antwort")
    }

    @MainActor
    func testReasoningIsOmittedWhenPreserveThinkingIsOff() {
        let vm = ChatViewModel()
        // Version 4.0: Preserve Thinking hängt am Modell.
        var settings = ModelSettings()
        settings.preserveThinking = false
        ModelSettingsRegistry.shared.update([ModelSettings.key(for: vm.activeProfile?.model ?? ""): settings])
        defer { ModelSettingsRegistry.shared.update([:]) }
        let msg = ChatMessage(role: "assistant", content: "Antwort", thinking: "Gedanke")
        let payload = vm.apiMessages(for: msg, provider: .omlx)
        XCTAssertNil(payload.first?["reasoning_content"])
    }

    @MainActor
    func testReasoningAccompaniesToolCalls() {
        let vm = ChatViewModel()
        vm.preserveThinking = true
        let call = ToolCallInfo(id: "c1", index: 0, name: "web_search", arguments: #"{"query":"x"}"#, result: "ok", source: nil)
        let msg = ChatMessage(role: "assistant", content: "", thinking: "Ich suche zuerst.", toolCalls: [call])
        let payload = vm.apiMessages(for: msg, provider: .omlx)
        XCTAssertEqual(payload.first?["reasoning_content"] as? String, "Ich suche zuerst.")
        XCTAssertEqual(payload.first?["content"] as? String, "", "Thinking nicht zusätzlich in den Text kopieren")
        XCTAssertEqual(payload.count, 2, "Tool-Ergebnis folgt")
    }

    func testTokenEstimateCountsReasoning() {
        let without = ChatViewModel.estimatedTokens(of: ["role": "assistant", "content": "kurz"])
        let with = ChatViewModel.estimatedTokens(of: ["role": "assistant", "content": "kurz", "reasoning_content": String(repeating: "a", count: 4_000)])
        XCTAssertGreaterThanOrEqual(with - without, 900)
    }

    // MARK: Schnelle Inline-Erklärung

    func testInlinePurposeDisablesThinking() throws {
        var profile = EndpointProfile.omlxLocal()
        profile.thinkingMode = .on
        let payload = ChatRequestBuilder(profile: profile)
            .payload(messages: [["role": "user", "content": "x"]], purpose: .inline, stream: true)
        let kwargs = payload["chat_template_kwargs"] as? [String: Any]
        XCTAssertEqual(kwargs?["enable_thinking"] as? Bool, false)
    }

    // MARK: Testablage

    func testUnitTestsNeverUseRealDataDirectory() {
        XCTAssertTrue(AppStorageLocation.isRunningUnitTests)
        XCTAssertFalse(AppStorageLocation.root.path.contains("Application Support/LernAssist"),
                       "Tests dürfen nicht in die echten Chats schreiben")
    }

    // MARK: PDF-Export

    @MainActor
    func testPDFExportWritesPaginatedPDFWithText() async throws {
        let sections = (1...14).map { i in
            "## Abschnitt \(i)\n\nDie **Michaelis-Konstante** beschreibt die Substratkonzentration bei halber Maximalgeschwindigkeit. "
            + String(repeating: "Ein Satz zur Erklärung des Zusammenhangs. ", count: 8)
        }
        let markdown = "# Lernzettel Enzymkinetik\n\n" + sections.joined(separator: "\n\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lernzettel-test-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        let ok = await StudySheetExporter.shared.renderPDF(markdown, to: url)
        XCTAssertTrue(ok, "PDF sollte Inhalt haben")
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertGreaterThanOrEqual(document.pageCount, 2, "A4-Umbruch statt einer Endlos-Seite")
        XCTAssertTrue((document.string ?? "").contains("Michaelis"), "Text muss im PDF stehen")
    }

    func testPageBreaksFollowElementBoundaries() {
        let ends: [CGFloat] = [100, 300, 520, 700, 900, 1250]
        let breaks = StudySheetExporter.pageBreaks(elementEnds: ends, totalHeight: 1300, pageHeight: 600)
        XCTAssertEqual(breaks, [520, 900, 1300], "Umbruch am letzten Element, das noch passt")
    }
}
