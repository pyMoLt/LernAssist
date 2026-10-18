import XCTest
@testable import Lernassist

/// Prefix-Cache-Stabilität: Tool-Runden, Bild-Regel und Kontext-Kürzung dürfen den Prompt-Anfang
/// zwischen zwei Anfragen nicht unnötig verändern.
final class Version3CacheTests: XCTestCase {

    // MARK: Bild-Regel („B mit Deckel“)

    private func imageMessage(_ text: String, description: String?) -> ChatMessage {
        var msg = ChatMessage(role: "user", content: text, imageBase64: "QQ==")
        msg.imageDescription = description
        return msg
    }

    private func viewModel(with messages: [ChatMessage]) -> ChatViewModel {
        let vm = ChatViewModel()
        vm.keepMultipleImagesInHistory = false
        vm.autoImageToTextEnabled = true
        var session = ChatSession(title: "Test")
        session.messages = messages
        vm.sessions = [session]
        return vm
    }

    func testNewestScreenshotStaysImageForFollowUps() {
        let vm = viewModel(with: [
            imageMessage("Was zeigt die Folie?", description: "Folie zur Niere"),
            ChatMessage(role: "assistant", content: "Die Niere filtert …"),
            ChatMessage(role: "user", content: "Und der Pfeil links?")
        ])
        vm.applyImageRetention(sessionIdx: 0)
        XCTAssertFalse(vm.sessions[0].messages[0].isImageContextFrozen)
        let payload = vm.apiMessages(for: vm.sessions[0].messages[0], provider: .omlx, screenshotNumber: 1)
        XCTAssertFalse(payload.first?["content"] is String, "Neuester Screenshot geht als Bild mit")
    }

    func testOlderScreenshotFreezesWhenNewOneArrives() {
        let vm = viewModel(with: [
            imageMessage("Folie 1", description: "Beschreibung 1"),
            ChatMessage(role: "assistant", content: "Antwort 1"),
            imageMessage("Folie 2", description: nil)
        ])
        vm.applyImageRetention(sessionIdx: 0)
        XCTAssertTrue(vm.sessions[0].messages[0].isImageContextFrozen)
        XCTAssertEqual(vm.sessions[0].messages[0].frozenImageContext, "Beschreibung 1")
        XCTAssertFalse(vm.sessions[0].messages[2].isImageContextFrozen)
    }

    func testScreenshotWithoutDescriptionIsNotFrozen() {
        let vm = viewModel(with: [
            imageMessage("Folie 1", description: nil),
            ChatMessage(role: "assistant", content: "Antwort 1"),
            imageMessage("Folie 2", description: nil)
        ])
        vm.applyImageRetention(sessionIdx: 0)
        XCTAssertFalse(vm.sessions[0].messages[0].isImageContextFrozen,
                       "Ohne fertige Beschreibung bleibt das Bild, statt den Inhalt zu verlieren")
    }

    func testNewestScreenshotFreezesBehindTokenCap() {
        let longAnswer = String(repeating: "Recherche-Ergebnis. ", count: 1_000) // ≈ 5k Tokens
        let vm = viewModel(with: [
            imageMessage("Folie", description: "Beschreibung"),
            ChatMessage(role: "assistant", content: longAnswer),
            ChatMessage(role: "user", content: "Noch eine Frage")
        ])
        vm.applyImageRetention(sessionIdx: 0)
        XCTAssertTrue(vm.sessions[0].messages[0].isImageContextFrozen)
    }

    // MARK: Tool-Runden

    func testRecalledScreenshotIsPartOfHistory() {
        let vm = ChatViewModel()
        var call = ToolCallInfo(id: "c1", index: 0, name: "recall_screenshot", arguments: "{\"number\":1}", result: "ok")
        call.recalledScreenshot = 1
        var message = ChatMessage(role: "assistant", content: "")
        message.toolCalls = [call]
        let payload = vm.apiMessages(for: message, provider: .omlx, recalledScreenshot: { $0 == 1 ? "QQ==" : nil })
        XCTAssertEqual(payload.count, 3, "assistant, tool, Bildnachricht")
        XCTAssertEqual(payload[2]["role"] as? String, "user")
    }

    // MARK: Kontext-Kürzung

    func testContextTrimCutStaysStableWhileHistoryGrows() {
        func turn(_ i: Int) -> [[String: Any]] {
            [["role": "user", "content": "Frage \(i) " + String(repeating: "x", count: 800)],
             ["role": "assistant", "content": "Antwort \(i) " + String(repeating: "y", count: 800)]]
        }
        var messages: [[String: Any]] = [["role": "system", "content": "System"]]
        for i in 0..<20 { messages += turn(i) }
        let first = ChatViewModel.trimmedToContextBudget(messages, contextWindow: 8_192, maxTokens: 1_024)
        messages += turn(20)
        let second = ChatViewModel.trimmedToContextBudget(messages, contextWindow: 8_192, maxTokens: 1_024)
        XCTAssertEqual(first[1]["content"] as? String, second[1]["content"] as? String,
                       "Der Verlaufsanfang bleibt gleich, solange kein ganzer Block dazugekommen ist")
    }

    func testUnknownContextWindowUsesLargeFallback() {
        var messages: [[String: Any]] = [["role": "system", "content": "System"]]
        for i in 0..<10 {
            messages.append(["role": "user", "content": "Frage \(i) " + String(repeating: "x", count: 3_000)])
            messages.append(["role": "assistant", "content": "Antwort"])
        }
        let trimmed = ChatViewModel.trimmedToContextBudget(messages, contextWindow: nil, maxTokens: nil)
        XCTAssertEqual(trimmed.count, messages.count, "≈ 8k Tokens passen in das 32k-Fallback")
    }

    // MARK: Freies Üben

    func testPracticeSelectionFiltersWithoutTouchingSchedule() {
        let chatA = UUID(), chatB = UUID()
        var forgotten = Flashcard(front: "F1", back: "B1")
        forgotten.lapses = 2
        let due = Date(timeIntervalSinceNow: 86_400 * 30)
        let fresh = Flashcard(front: "F2", back: "B2", dueDate: due)
        let other = Flashcard(front: "F3", back: "B3")
        let cards = [
            ChatViewModel.DueFlashcard(card: forgotten, sessionId: chatA, sessionTitle: "A", setId: UUID(), setTitle: "", sessionSubject: "Physiologie"),
            ChatViewModel.DueFlashcard(card: fresh, sessionId: chatA, sessionTitle: "A", setId: UUID(), setTitle: "", sessionSubject: "Physiologie"),
            ChatViewModel.DueFlashcard(card: other, sessionId: chatB, sessionTitle: "B", setId: UUID(), setTitle: "", sessionSubject: "Informatik")
        ]
        func pick(_ options: ChatViewModel.PracticeOptions) -> Set<String> {
            Set(ChatViewModel.practiceCards(from: cards, options: options, activeSessionId: chatB).map(\.card.front))
        }
        XCTAssertEqual(pick(.init(source: .all, limit: nil)), ["F1", "F2", "F3"], "Auch nicht fällige Karten")
        XCTAssertEqual(pick(.init(source: .currentChat, limit: nil)), ["F3"])
        XCTAssertEqual(pick(.init(source: .subjects(["Physiologie"]), limit: nil)), ["F1", "F2"])
        XCTAssertEqual(pick(.init(source: .chats([chatB]), limit: nil)), ["F3"])
        XCTAssertEqual(pick(.init(source: .all, onlyMistakes: true, limit: nil)), ["F1"])
        XCTAssertEqual(ChatViewModel.practiceCards(from: cards, options: .init(source: .all, limit: 2), activeSessionId: nil).count, 2)
    }

    // MARK: Bildkarten

    func testGeneratedCardsKeepAtMostOneValidImage() {
        let raw = #"{"cards": [{"front": "Welche Struktur?", "back": "Glomerulus", "image": 1}, {"front": "B", "back": "b", "image": 1}, {"front": "C", "back": "c", "image": 0}]}"#
        let cards = ChatViewModel.parseGeneratedCards(raw, imageCount: 1)
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(cards[0].image, 1)
        XCTAssertNil(cards[1].image, "Höchstens eine Bildkarte pro Nachricht")
        XCTAssertNil(cards[2].image)
        XCTAssertNil(ChatViewModel.parseGeneratedCards(#"{"cards": [{"front": "A", "back": "a", "image": 4}]}"#, imageCount: 1)[0].image,
                     "Ungültige Bildnummer wird ignoriert")
    }

    func testTurnImagesCoverQuestionAndAnswer() {
        let question = ChatMessage(role: "user", content: "Was zeigt das?", imageBase64: "QQ==")
        let plot = ChatMessage(role: "assistant", content: "", imageBase64: "Qg==")
        let answer = ChatMessage(role: "assistant", content: "Das ist …")
        let later = ChatMessage(role: "user", content: "Danke", imageBase64: "Qw==")
        let images = ChatViewModel.turnImages(in: [question, plot, answer, later], answerId: answer.id)
        XCTAssertEqual(images, ["QQ==", "Qg=="])
        XCTAssertTrue(ChatViewModel.turnImages(in: [ChatMessage(role: "user", content: "x"), answer], answerId: answer.id).isEmpty)
    }

    // MARK: Deterministisches JSON

    func testRequestBodyIsIndependentOfDictionaryOrder() throws {
        var a: [String: Any] = [:]
        a["tools"] = [["type": "function", "function": ["name": "x", "description": "d", "parameters": ["type": "object"]]]]
        a["model"] = "m"
        a["stream"] = true
        var b: [String: Any] = [:]
        b["stream"] = true
        b["model"] = "m"
        b["tools"] = [["function": ["parameters": ["type": "object"], "description": "d", "name": "x"], "type": "function"]]
        XCTAssertEqual(try ChatRequestBuilder.serialize(a), try ChatRequestBuilder.serialize(b))
    }
}
