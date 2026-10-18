import XCTest
@testable import Lernassist

/// Tests für Version 3.0: FSRS Spaced Repetition, Fehlerlog, Slash-Befehle, Titel/Fach und Persistenz.
final class Version3Tests: XCTestCase {

    // MARK: - FSRS Spaced Repetition

    func testFSRSInitialRatings() {
        let scheduler = FSRS()
        var card = Flashcard(front: "Frage", back: "Antwort")
        XCTAssertTrue(card.isNew)
        XCTAssertNil(card.stability)
        XCTAssertNil(card.difficulty)

        let now = Date()
        card.applyReview(.good, now: now, scheduler: scheduler)
        XCTAssertFalse(card.isNew)
        XCTAssertNotNil(card.stability)
        XCTAssertNotNil(card.difficulty)
        XCTAssertEqual(card.repetitionCount, 1)
        XCTAssertGreaterThanOrEqual(card.intervalDays, 1.0)
        XCTAssertEqual(card.lapses, 0)
    }

    func testFSRSForgettingSchedulesTenMinutesAndIncrementsLapses() {
        let scheduler = FSRS()
        var card = Flashcard(front: "Mitochondrium", back: "Kraftwerk der Zelle")
        let start = Date()

        // Erstes Lernen (Gut)
        card.applyReview(.good, now: start, scheduler: scheduler)
        XCTAssertEqual(card.repetitionCount, 1)

        // Nach 3 Tagen vergessen (Nochmal)
        let threeDaysLater = start.addingTimeInterval(3 * 86_400)
        card.applyReview(.again, now: threeDaysLater, scheduler: scheduler)

        XCTAssertEqual(card.repetitionCount, 0, "Repetition count resets on lapse")
        XCTAssertEqual(card.intervalDays, 0, "Interval resets to 0 on lapse")
        XCTAssertEqual(card.lapses, 1, "Lapses incremented")
        // Fälligkeit genau 10 Minuten nach dem Fehlversuch
        let diff = card.dueDate.timeIntervalSince(threeDaysLater)
        XCTAssertEqual(diff, 600, accuracy: 2.0, "Due date should be 10 minutes in the future")
    }

    func testFSRSSuccessGrowsInterval() {
        let scheduler = FSRS()
        var card = Flashcard(front: "DNS", back: "Desoxyribonukleinsäure")
        var current = Date()

        card.applyReview(.good, now: current, scheduler: scheduler)
        let firstInterval = card.intervalDays
        XCTAssertGreaterThanOrEqual(firstInterval, 1.0)

        // Nächster Review nach Ablauf des Intervalls
        current = current.addingTimeInterval(firstInterval * 86_400)
        card.applyReview(.good, now: current, scheduler: scheduler)
        let secondInterval = card.intervalDays
        XCTAssertGreaterThan(secondInterval, firstInterval, "Interval should grow on successful repetition")
        XCTAssertEqual(card.repetitionCount, 2)
    }

    func testFSRSMigrationFromLegacySM2Cards() {
        let scheduler = FSRS()
        // Alte SM-2-Karte vor FSRS: kein stability, repetitionCount > 0, intervalDays und easeFactor gesetzt
        var legacyCard = Flashcard(
            front: "Glykolyse",
            back: "Glukoseabbau",
            dueDate: Date().addingTimeInterval(-86_400),
            intervalDays: 7,
            easeFactor: 2.5,
            repetitionCount: 3,
            lastReviewedAt: Date().addingTimeInterval(-7 * 86_400)
        )
        XCTAssertNil(legacyCard.stability)
        XCTAssertNil(legacyCard.difficulty)

        let now = Date()
        legacyCard.applyReview(.good, now: now, scheduler: scheduler)

        XCTAssertNotNil(legacyCard.stability, "Stability should be initialized from previous interval")
        XCTAssertNotNil(legacyCard.difficulty, "Difficulty should be mapped from previous ease factor")
        XCTAssertEqual(legacyCard.repetitionCount, 4)
    }

    // MARK: - MistakeStore Merging

    func testMistakeStoreMergingNewEntry() {
        let entry1 = MistakeEntry(
            kind: .quiz,
            question: "Welches Enzym spaltet Stärke?",
            givenAnswer: "Lipase",
            correctAnswer: "Amylase"
        )
        let merged = MistakeStore.merging(entry1, into: [])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.question, "Welches Enzym spaltet Stärke?")
        XCTAssertEqual(merged.first?.count, 1)
    }

    func testMistakeStoreMergingDuplicateIncrementsCount() {
        let now = Date()
        let entry1 = MistakeEntry(
            kind: .quiz,
            question: "Hauptfunktion von Ribosomen?",
            givenAnswer: "Lipidsynthese",
            correctAnswer: "Proteinsynthese",
            count: 1
        )
        let existing = [entry1]

        let later = now.addingTimeInterval(300)
        let duplicate = MistakeEntry(
            kind: .quiz,
            date: later,
            question: "Hauptfunktion von Ribosomen?",
            givenAnswer: "Zellteilung",
            correctAnswer: "Proteinsynthese"
        )

        let merged = MistakeStore.merging(duplicate, into: existing)
        XCTAssertEqual(merged.count, 1, "Should merge into existing entry without creating duplicates")
        XCTAssertEqual(merged.first?.count, 2, "Count should be incremented to 2")
        XCTAssertEqual(merged.first?.givenAnswer, "Zellteilung", "Latest given answer should be preserved")
    }

    func testMistakeStoreDoesNotMergeIntoResolvedEntry() {
        var resolved = MistakeEntry(
            kind: .quiz,
            question: "Osmose Definition",
            isResolved: true
        )
        resolved.count = 1

        let newEntry = MistakeEntry(
            kind: .quiz,
            question: "Osmose Definition"
        )

        let merged = MistakeStore.merging(newEntry, into: [resolved])
        XCTAssertEqual(merged.count, 2, "Resolved entry should not absorb new mistakes")
        XCTAssertFalse(merged[0].isResolved)
        XCTAssertTrue(merged[1].isResolved)
    }

    // MARK: - Slash Command Parsing

    func testParseQuizArguments() {
        let q1 = ChatViewModel.parseQuizArguments("5 Citratzyklus")
        XCTAssertEqual(q1.count, 5)
        XCTAssertNil(q1.difficulty)
        XCTAssertEqual(q1.topic, "Citratzyklus")

        let q2 = ChatViewModel.parseQuizArguments("Niere")
        XCTAssertNil(q2.count)
        XCTAssertEqual(q2.topic, "Niere")

        XCTAssertEqual(ChatViewModel.parseQuizArguments("10").count, 10)

        let q4 = ChatViewModel.parseQuizArguments("100 Riesenthema")
        XCTAssertNil(q4.count, "Count outside 1...30 should fall back to entire text as topic")
        XCTAssertEqual(q4.topic, "100 Riesenthema")

        let empty = ChatViewModel.parseQuizArguments("")
        XCTAssertNil(empty.count)
        XCTAssertEqual(empty.topic, "")

        let q5 = ChatViewModel.parseQuizArguments("10 schwer Niere")
        XCTAssertEqual(q5.count, 10)
        XCTAssertEqual(q5.difficulty, .hard)
        XCTAssertEqual(q5.topic, "Niere")

        let q6 = ChatViewModel.parseQuizArguments("sehr schwer 5 Säure-Base-Haushalt")
        XCTAssertEqual(q6.difficulty, .veryHard)
        XCTAssertEqual(q6.count, 5)
        XCTAssertEqual(q6.topic, "Säure-Base-Haushalt")

        XCTAssertEqual(ChatViewModel.parseQuizArguments("leicht").difficulty, .easy)
        // „Schwere Ketten“ ist ein Thema, keine Stufe.
        XCTAssertNil(ChatViewModel.parseQuizArguments("Schwere Ketten").difficulty)

        XCTAssertTrue(ChatViewModel.quizPrompt(count: 3, topic: "Niere", difficulty: .hard).contains(StudyDifficulty.hard.quizGuidance))
        XCTAssertFalse(ChatViewModel.quizPrompt(count: 3, topic: "Niere").contains("Schwierigkeit"))
    }

    func testSlashParameterGhostShrinksWhileTyping() {
        let hint = "[Anzahl] [leicht|mittel|schwer|sehr schwer] [Thema]"
        XCTAssertEqual(InputArea.remainingParameters(hint: hint, typedArguments: 0), hint)
        XCTAssertEqual(InputArea.remainingParameters(hint: hint, typedArguments: 1), "[leicht|mittel|schwer|sehr schwer] [Thema]")
        XCTAssertNil(InputArea.remainingParameters(hint: hint, typedArguments: 3))
        XCTAssertEqual(InputArea.remainingParameters(hint: "<URL>", typedArguments: 0), "<URL>")
    }

    // MARK: - Title and Subject Parsing

    func testParseTitleAndSubjectJSON() {
        let raw = #"{"title": "Zellatmung und Glykolyse", "subject": "Biologie"}"#
        let parsed = ChatViewModel.parseTitleAndSubject(raw)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.title, "Zellatmung und Glykolyse")
        XCTAssertEqual(parsed?.subject, "Biologie")
    }

    func testParseTitleAndSubjectMarkdownFences() {
        let raw = """
        ```json
        {
          "title": "Klinischer Fall: Appendizitis",
          "subject": "Medizin"
        }
        ```
        """
        let parsed = ChatViewModel.parseTitleAndSubject(raw)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.title, "Klinischer Fall: Appendizitis")
        XCTAssertEqual(parsed?.subject, "Medizin")
    }

    func testParseTitleAndSubjectFallbackPlainText() {
        let raw = "Einführung in Algorithmen"
        let parsed = ChatViewModel.parseTitleAndSubject(raw)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.title, "Einführung in Algorithmen")
        XCTAssertNil(parsed?.subject)
    }

    // MARK: - Flashcards Parsing

    func testParseFlashcardsObjectWithArray() {
        let json = """
        {
          "cards": [
            { "front": "Was ist die Funktion des Hämoglobins?", "back": "Sauerstofftransport im Blut" },
            { "front": "Wo wird Insulin gebildet?", "back": "B-Zellen der Langerhans-Inseln im Pankreas" }
          ]
        }
        """
        let cards = ChatViewModel.parseFlashcards(json)
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards[0].front, "Was ist die Funktion des Hämoglobins?")
        XCTAssertEqual(cards[0].back, "Sauerstofftransport im Blut")
        XCTAssertEqual(cards[1].front, "Wo wird Insulin gebildet?")
    }

    func testParseFlashcardsNakedArrayWithTrailingComma() {
        let json = """
        [
          { "front": "Neuron", "back": "Nervenzelle" },
        ]
        """
        let cards = ChatViewModel.parseFlashcards(json)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].front, "Neuron")
        XCTAssertEqual(cards[0].back, "Nervenzelle")
    }

    // MARK: - PersistedSettings Decoding

    func testPersistedSettingsDecodesExistingInstallWithProfilesAsSetupCompleted() throws {
        // Bestehende settings.json ohne 'setupCompleted', aber mit 'profiles':
        let json = """
        {
          "profiles": [
            {
              "id": "11111111-2222-3333-4444-555555555555",
              "name": "Mein Server",
              "baseURL": "http://127.0.0.1:8072",
              "model": "qwen",
              "isRemote": false
            }
          ]
        }
        """
        let data = json.data(using: .utf8)!
        let settings = try JSONDecoder().decode(PersistedSettings.self, from: data)
        XCTAssertTrue(settings.setupCompleted, "Existing installation with profiles should be considered setupCompleted = true")
        XCTAssertEqual(settings.autoArchiveDays, 7, "Default autoArchiveDays should be 7")
        XCTAssertEqual(settings.flashcardRetention, 0.9, accuracy: 0.001, "Default flashcardRetention should be 0.9")
    }

    func testPersistedSettingsDecodesFreshInstallWithoutProfilesAsSetupIncomplete() throws {
        // Frische Installation ohne 'setupCompleted' und ohne 'profiles':
        let json = "{}"
        let data = json.data(using: .utf8)!
        let settings = try JSONDecoder().decode(PersistedSettings.self, from: data)
        XCTAssertFalse(settings.setupCompleted, "Fresh install without profiles should have setupCompleted = false")
    }

    // MARK: - StudySheetExporter FileName

    func testStudySheetExporterFileName() {
        let title = StudySheetExporter.fileName(from: "# Übersicht: Herz-Kreislauf-System\nWeitere Details...")
        XCTAssertEqual(title, "Übersicht Herz-Kreislauf-System", "Colons should be stripped for safe filesystem naming")

        let fallback = StudySheetExporter.fileName(from: "")
        XCTAssertEqual(fallback, "Lernzettel")
    }

    // MARK: - Code Sanitizer & Prompts

    func testSanitizePythonCodeStripsLeadingAngleBracketAndFences() {
        let codeWithStrayBracket = "<html_content = open('output.html', 'w')\nhtml_content.write('<h1>Test</h1>')\n"
        let sanitizedBracket = CodingEnvironment.sanitizePythonCode(codeWithStrayBracket)
        XCTAssertEqual(sanitizedBracket, "html_content = open('output.html', 'w')\nhtml_content.write('<h1>Test</h1>')")

        let codeWithMarkdownFence = "```python\nimport math\nprint(math.pi)\n```"
        let sanitizedFence = CodingEnvironment.sanitizePythonCode(codeWithMarkdownFence)
        XCTAssertEqual(sanitizedFence, "import math\nprint(math.pi)")

        let codeWithPseudoTag = "<python>\nx = 42\nprint(x)"
        let sanitizedTag = CodingEnvironment.sanitizePythonCode(codeWithPseudoTag)
        XCTAssertEqual(sanitizedTag, "x = 42\nprint(x)")
    }

    func testSanitizeHTMLCodeStripsMarkdownFences() {
        let rawHTML = "```html\n<div class=\"chart\">Plot</div>\n```"
        let clean = CodingTool.sanitizeHTMLCode(rawHTML)
        XCTAssertEqual(clean, "<div class=\"chart\">Plot</div>")
    }

    func testToolRegistryPromptGuidesCodingToolWithoutForcingIt() {
        let addition = ToolRegistry.shared.systemPromptAddition
        XCTAssertTrue(addition.contains("coding_sandbox"))
        XCTAssertTrue(addition.contains("Python oder HTML"), "Modell soll frei zwischen Python und HTML wählen")
        XCTAssertTrue(addition.contains("Code selbst"), "Code-Erklärungen gehören in den Chat")
        XCTAssertFalse(addition.contains("IMMER"), "Kein harter Zwang mehr")
    }

    // MARK: - Telemetry Smoothing

    func testRollingTokenSamplesSmoothing() {
        let now = Date()
        var samples: [(time: Date, charCount: Int)] = [
            (time: now.addingTimeInterval(-4.0), charCount: 0),
            (time: now.addingTimeInterval(-3.0), charCount: 100),
            (time: now.addingTimeInterval(-2.0), charCount: 250),
            (time: now.addingTimeInterval(-1.0), charCount: 400),
            (time: now, charCount: 570)
        ]
        let windowDuration: TimeInterval = 3.5
        let windowCutoff = now.addingTimeInterval(-windowDuration)
        samples.removeAll(where: { $0.time < windowCutoff })
        XCTAssertEqual(samples.count, 4, "Oldest sample outside 3.5s window should be purged")

        let oldest = samples.first!
        let dt = now.timeIntervalSince(oldest.time)
        let dTokens = Double(570 - oldest.charCount) / 3.8
        let windowTps = dTokens / dt
        XCTAssertGreaterThan(windowTps, 35.0)
        XCTAssertLessThan(windowTps, 45.0)
    }

    // MARK: - E2E Integration: Quiz Card to Flashcard & Undo

    @MainActor
    func testRememberQuizCardAndUndo() {
        let vm = ChatViewModel()
        let testSessionId = UUID()
        let quizCard = QuizCard(
            question: "Welches Enzym katalysiert den ersten Schritt der Glykolyse?",
            options: ["Hexokinase", "Phosphofruktokinase", "Pyruvatkinase"],
            correctIndex: 0,
            explanation: "Die Hexokinase phosphoryliert Glucose zu Glucose-6-Phosphat."
        )
        var msg = ChatMessage(id: UUID(), role: "assistant", content: "Hier ist die Frage:")
        msg.quizCard = quizCard
        var session = ChatSession(id: testSessionId, title: "Biochemie Quiz")
        session.messages = [msg]
        vm.sessions = [session]
        vm.activeSessionId = testSessionId

        vm.rememberQuizCard(messageId: msg.id)

        XCTAssertNotNil(vm.flashcardNotice, "Flashcard notice should be presented")
        XCTAssertEqual(vm.flashcardNotice?.text, "1 Karte gemerkt")
        let updatedSession = vm.sessions.first(where: { $0.id == testSessionId })
        let sets = updatedSession?.flashcardSets ?? []
        XCTAssertFalse(sets.isEmpty, "Flashcard set should be created in the session")
        let card = sets.first?.cards.first
        XCTAssertEqual(card?.front, "Welches Enzym katalysiert den ersten Schritt der Glykolyse?")
        XCTAssertTrue(card?.back.contains("Hexokinase") ?? false)

        if let notice = vm.flashcardNotice {
            vm.undoFlashcardNotice(notice)
        }
        XCTAssertNil(vm.flashcardNotice, "Flashcard notice should be cleared after undo")
        let sessionAfterUndo = vm.sessions.first(where: { $0.id == testSessionId })
        let cardsAfterUndo = sessionAfterUndo?.flashcardSets?.first?.cards ?? []
        XCTAssertTrue(cardsAfterUndo.isEmpty, "Card should be removed after undo")
    }

    // MARK: - E2E Integration: Mistake Training

    @MainActor
    func testMistakeTrainingSessionCreation() {
        let vm = ChatViewModel()
        let mistake = MistakeEntry(
            kind: .quiz,
            subject: "Biologie",
            question: "Was ist die Funktion von Mitochondrien?",
            givenAnswer: "Photosynthese",
            correctAnswer: "Zellatmung / ATP-Produktion"
        )
        vm.mistakes = [mistake]
        XCTAssertEqual(vm.openMistakes.count, 1)

        vm.startMistakeTraining(subject: "Biologie")

        guard let activeSession = vm.activeSession else {
            return XCTFail("Active session should exist after starting training")
        }
        XCTAssertTrue(activeSession.title.hasPrefix("Training aus Fehlern"))
        XCTAssertEqual(activeSession.subject, "Biologie")
        XCTAssertFalse(activeSession.messages.isEmpty)
        let sentMessage = activeSession.messages.first?.content ?? ""
        XCTAssertTrue(sentMessage.contains("Was ist die Funktion von Mitochondrien?"))
        XCTAssertTrue(sentMessage.contains("Zellatmung / ATP-Produktion"))
    }

    // MARK: - E2E Integration: Slash Prompts

    func testSlashCommandStudySheetPrompt() {
        let prompt = ChatViewModel.studySheetPrompt(focus: "Citratzyklus")
        XCTAssertTrue(prompt.contains("Citratzyklus"))
        XCTAssertTrue(prompt.contains("Lernzettel"))
        XCTAssertTrue(prompt.contains("Kernaussagen"))
    }

    func testSlashCommandCasePrompt() {
        let prompt = ChatViewModel.casePrompt(topic: "Blinddarmentzündung")
        XCTAssertTrue(prompt.contains("Blinddarmentzündung"))
        XCTAssertTrue(prompt.contains("Schritt"))
    }

    // MARK: - E2E Integration: App Menu Setup

    @MainActor
    func testMainMenuSettingsItem() {
        let delegate = AppDelegate()
        delegate.setupMainMenu()

        let mainMenu = NSApp.mainMenu
        XCTAssertNotNil(mainMenu, "NSApp.mainMenu should not be nil")
        guard let appMenu = mainMenu?.items.first?.submenu else {
            return XCTFail("App submenu should exist")
        }

        let settingsItem = appMenu.items.first(where: { $0.title.contains("Einstellungen") })
        XCTAssertNotNil(settingsItem, "Settings item should be present in app menu")
        XCTAssertEqual(settingsItem?.keyEquivalent, ",", "Settings key equivalent should be ','")
    }

    // MARK: - Tool-Limit & URL-Browsing Tests

    func testFinalToolRoundNoticeOnlyInLastToolResult() {
        let vm = ChatViewModel()
        vm.preserveThinking = true
        var first = ToolCallInfo(id: "call_1", index: 0, name: "web_search", arguments: "{\"query\": \"a\"}")
        first.result = "Ergebnis A"
        var last = ToolCallInfo(id: "call_2", index: 1, name: "web_search", arguments: "{\"query\": \"b\"}")
        last.result = "Ergebnis B"
        last.limitNote = .finalRound
        var message = ChatMessage(role: "assistant", content: "")
        message.thinking = "Ich suche zwei Dinge."
        message.toolCalls = [first, last]

        let payload = vm.apiMessages(for: message, provider: .omlx)
        XCTAssertEqual(payload.count, 3)
        // Das Thinking geht auch in Tool-Runden mit (identisch zum späteren Verlauf).
        XCTAssertEqual(payload[0]["reasoning_content"] as? String, "Ich suche zwei Dinge.")
        XCTAssertEqual(payload[1]["content"] as? String, "Ergebnis A")
        let lastContent = payload[2]["content"] as? String ?? ""
        XCTAssertTrue(lastContent.hasPrefix("Ergebnis B"))
        XCTAssertTrue(lastContent.hasSuffix(ChatViewModel.toolFinalRoundNotice))
    }

    func testToolLimitPresentationInWorkStepsView() {
        var call = ToolCallInfo(
            id: "call_limit",
            index: 0,
            name: "web_search",
            arguments: "{\"query\": \"test\"}",
            result: ChatViewModel.toolLimitNotExecutedMessage
        )
        call.limitNote = .notExecuted
        let presentation = ToolCallPresentation(call: call)
        XCTAssertTrue(presentation.isLimitReached, "Should be recognized as limit reached")
        XCTAssertFalse(presentation.isError, "Limit reached should not be treated as error")

        var executed = ToolCallInfo(id: "call_ok", index: 0, name: "web_search", arguments: "{}", result: "ok")
        executed.limitNote = .finalRound
        XCTAssertFalse(ToolCallPresentation(call: executed).isLimitReached)

        var message = ChatMessage(role: "assistant", content: "")
        message.toolCalls = [call]
        let steps = WorkStep.steps(from: [message])
        XCTAssertEqual(steps.count, 1)
        if case .tool(let c) = steps[0].kind {
            XCTAssertEqual(c.id, "call_limit")
        } else {
            XCTFail("Expected tool workstep")
        }
    }

    func testBrowseURLToolArgumentParsingLogic() {
        func resolve(_ json: String, _ question: String?) -> (focus: String, offset: Int) {
            BrowseURLTool.resolveFocusAndOffset(arguments: ToolArguments.object(json), question: question)
        }
        let url = "{\"url\": \"https://example.com\"}"

        // 1. Weder focus noch offset -> Nutzerfrage wird focus
        let res1 = resolve(url, "Wie funktioniert die DNS-Auflösung genau?")
        XCTAssertEqual(res1.focus, "Wie funktioniert die DNS-Auflösung genau?")
        XCTAssertEqual(res1.offset, 0)

        // 2. Explizites offset (auch 0) -> Abschnitte, kein Fokus
        let res2 = resolve("{\"url\": \"https://example.com\", \"offset\": 0}", "Wie funktioniert die DNS-Auflösung genau?")
        XCTAssertEqual(res2.focus, "")
        let res3 = resolve("{\"url\": \"https://example.com\", \"offset\": 5000}", "Was ist DNS?")
        XCTAssertEqual(res3.focus, "")
        XCTAssertEqual(res3.offset, 5000)

        // 3. Explizites focus -> wird unverändert genutzt
        XCTAssertEqual(resolve("{\"url\": \"https://example.com\", \"focus\": \"Replikation\"}", "Was ist DNS?").focus, "Replikation")

        // 4. Nur ein Link oder Wunsch nach Zusammenfassung -> der Reihe nach
        XCTAssertEqual(resolve(url, "https://example.com/artikel").focus, "")
        XCTAssertEqual(resolve(url, "Lies mal: https://example.com/artikel").focus, "")
        XCTAssertEqual(resolve(url, "Kannst du mir diesen Artikel bitte zusammenfassen? https://example.com").focus, "")
        XCTAssertEqual(resolve(url, "Fass mir die Seite kurz zusammen https://example.com").focus, "")
        XCTAssertEqual(resolve(url, "Lies bitte die ganze Seite durch https://example.com").focus, "")
    }

    // MARK: - Settings: Decoding Defaults & Reset To Defaults

    func testPersistedSettingsDecodesMissingNewKeysWithDefaults() throws {
        // Simuliert eine ältere settings.json ohne die neuen "Erweitert"-Schlüssel
        let legacyJson = """
        {
            "version": 1,
            "profiles": [],
            "learningStyle": "standard",
            "searchEnabled": true,
            "searxngURL": "http://localhost:8080",
            "maxBrowseCharacters": 8000
        }
        """
        let data = legacyJson.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PersistedSettings.self, from: data)

        // Neue Keys müssen auf ihre Standardwerte fallen (die ursprünglichen festen Code-Konstanten)
        XCTAssertEqual(decoded.pythonSandboxTimeout, 150)
        XCTAssertEqual(decoded.pythonMaxOutputCharacters, 10_000)
        XCTAssertEqual(decoded.pythonMaxScriptVersions, 10)
        XCTAssertEqual(decoded.pythonPlotDpi, 150)
        XCTAssertEqual(decoded.documentCacheDuration, 600)
        XCTAssertEqual(decoded.flashcardAgainDelayMinutes, 10)
        XCTAssertEqual(decoded.flashcardCardsPerResponse, 3)
        XCTAssertEqual(decoded.titleRefinementTurns, 3)
        XCTAssertEqual(decoded.documentImageBudget, 12)
        XCTAssertEqual(decoded.inlineExplainRadius, 400)
        XCTAssertEqual(decoded.maxToolRounds, 8)
        XCTAssertEqual(decoded.research.rerankerWindow, 60)
    }

    @MainActor
    func testResetToDefaultsPreservesEndpointsAndResetsOtherSettings() {
        let vm = ChatViewModel()

        // 1. Benutzerdefinierte Endpunkt-Profile anlegen
        var customProfile1 = EndpointProfile(
            name: "Mein Lokaler Server",
            baseURL: "http://192.168.1.100:11434",
            apiKey: "secret-key-123",
            model: "custom-llama3:8b",
            params: ModelParams(temperature: 0.2, topP: 0.8, topK: 40),
            isRemote: true,
            contextSizeOverride: 16384,
            provider: .openAICompatible
        )
        customProfile1.thinkingMode = .on
        customProfile1.thinkingBudget = 2048
        customProfile1.requestTimeout = 120

        var customProfile2 = EndpointProfile(
            name: "Cloud Fallback",
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-openai-key",
            model: "gpt-4o",
            params: ModelParams(temperature: 0.9),
            isRemote: true,
            provider: .openAICompatible
        )
        customProfile2.thinkingMode = .off
        customProfile2.thinkingBudget = 4096
        customProfile2.requestTimeout = 60

        vm.profiles = [customProfile1, customProfile2]
        vm.activeProfileID = customProfile1.id

        // 2. Modifiziere sonstige Parameter weg von Defaults
        vm.maxToolRounds = 18
        vm.pythonSandboxTimeout = 240
        vm.pythonMaxOutputCharacters = 25000
        vm.pythonMaxScriptVersions = 20
        vm.pythonPlotDpi = 220
        vm.documentCacheDuration = 900
        vm.flashcardAgainDelayMinutes = 30
        vm.flashcardCardsPerResponse = 5
        vm.titleRefinementTurns = 7
        vm.documentImageBudget = 25
        vm.inlineExplainRadius = 900
        vm.research.rerankerWindow = 120
        vm.research.apiContactEmail = "test@example.org"
        vm.research.enabledSources = [.wikipedia]
        vm.learningStyle = .detailed
        vm.customPrompts = ["detailed": "Mein eigener Prompt"]

        // 3. Reset ausführen
        vm.resetToDefaults()

        // 4. Prüfen: Endpunkt-Profile bleiben unverändert erhalten
        XCTAssertEqual(vm.profiles.count, 2)
        XCTAssertEqual(vm.profiles[0].id, customProfile1.id)
        XCTAssertEqual(vm.profiles[0].name, "Mein Lokaler Server")
        XCTAssertEqual(vm.profiles[0].baseURL, "http://192.168.1.100:11434")
        XCTAssertEqual(vm.profiles[0].apiKey, "secret-key-123")
        XCTAssertEqual(vm.profiles[0].model, "custom-llama3:8b")
        XCTAssertEqual(vm.profiles[0].provider, .openAICompatible)
        XCTAssertEqual(vm.profiles[0].contextSizeOverride, 16384)

        XCTAssertEqual(vm.profiles[1].id, customProfile2.id)
        XCTAssertEqual(vm.profiles[1].name, "Cloud Fallback")
        XCTAssertEqual(vm.profiles[1].baseURL, "https://api.openai.com/v1")
        XCTAssertEqual(vm.profiles[1].apiKey, "sk-openai-key")
        XCTAssertEqual(vm.profiles[1].model, "gpt-4o")
        XCTAssertEqual(vm.profiles[1].provider, .openAICompatible)

        // Sampling / Thinking der Profile bleiben ebenfalls (gehören zum Endpunkt)
        XCTAssertEqual(vm.profiles[0].params.temperature, 0.2)
        XCTAssertEqual(vm.profiles[0].thinkingMode, .on)
        XCTAssertEqual(vm.profiles[0].thinkingBudget, 2048)
        XCTAssertEqual(vm.profiles[0].requestTimeout, 120)
        XCTAssertEqual(vm.profiles[1].params.temperature, 0.9)

        // 5. Prüfen: Alle übrigen Parameter sind wieder Default
        XCTAssertEqual(vm.maxToolRounds, 8)
        XCTAssertEqual(vm.pythonSandboxTimeout, 150)
        XCTAssertEqual(vm.pythonMaxOutputCharacters, 10_000)
        XCTAssertEqual(vm.pythonMaxScriptVersions, 10)
        XCTAssertEqual(vm.pythonPlotDpi, 150)
        XCTAssertEqual(vm.documentCacheDuration, 600)
        XCTAssertEqual(vm.flashcardAgainDelayMinutes, 10)
        XCTAssertEqual(vm.flashcardCardsPerResponse, 3)
        XCTAssertEqual(vm.titleRefinementTurns, 3)
        XCTAssertEqual(vm.documentImageBudget, 12)
        XCTAssertEqual(vm.inlineExplainRadius, 400)
        XCTAssertEqual(vm.research.rerankerWindow, 60)

        // 6. Prüfen: Persönliche Einstellungen bleiben
        XCTAssertEqual(vm.learningStyle, .detailed)
        XCTAssertEqual(vm.customPrompts, ["detailed": "Mein eigener Prompt"])
        XCTAssertEqual(vm.research.apiContactEmail, "test@example.org")
        XCTAssertEqual(vm.research.enabledSources, [.wikipedia])
    }
}



