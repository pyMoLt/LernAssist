import XCTest
@testable import Lernassist

/// Einstellungen pro Modell (Version 4.0): Vorrang vor dem Profil, Vorlagen, Request-Felder.
final class ModelSettingsTests: XCTestCase {
    override func tearDown() { ModelSettingsRegistry.shared.update([:]) }

    func testKeyIgnoresPathAndCase() {
        XCTAssertEqual(ModelSettings.key(for: "mlx-community/Qwen3.6-35B-A3B-4bit"), "qwen3.6-35b-a3b-4bit")
        XCTAssertEqual(ModelSettings.key(for: " Sage-A1.5-oQ4e-fp16-mtp "), "sage-a1.5-oq4e-fp16-mtp")
    }

    func testPresetsAreRecognized() {
        XCTAssertEqual(ModelPreset.matching("Sage-A1.5-oQ4e-fp16-mtp")?.supportsVerification, true)
        XCTAssertEqual(ModelPreset.matching("Qwen3.8-27B-MLX-4bit")?.effortLevels, ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(ModelPreset.matching("Qwen3.6-35B-A3B-oQ4e-fp16-mtp")?.name, "Qwen3.5 / 3.6")
        XCTAssertNil(ModelPreset.matching("gpt-oss-20b"))
    }

    func testModelSettingsOverrideProfileInPayload() {
        var profile = EndpointProfile.omlxLocal()
        profile.model = "Sage-A1.5-oQ4e-fp16-mtp"
        profile.params.temperature = 0.7
        var settings = ModelSettings()
        settings.temperature = 1.0
        settings.topK = 20
        settings.minP = 0
        settings.thinking = .on
        settings.thinkingBudget = 2_000
        settings.reasoningEffort = "high"
        settings.preserveThinking = false
        settings.verification = true
        settings.templateKwargs = ["custom_flag": "true", "level": "3"]
        ModelSettingsRegistry.shared.update([ModelSettings.key(for: profile.model): settings])

        let payload = ChatRequestBuilder(profile: profile).payload(messages: [["role": "user", "content": "x"]], purpose: .chat, stream: true)
        XCTAssertEqual(payload["temperature"] as? Double, 1.0, "Modell vor Profil")
        XCTAssertEqual(payload["top_k"] as? Int, 20)
        XCTAssertEqual(payload["min_p"] as? Double, 0)
        XCTAssertEqual(payload["reasoning_effort"] as? String, "high")
        XCTAssertEqual(payload["thinking_budget"] as? Int, 2_000)
        let kwargs = payload["chat_template_kwargs"] as? [String: Any]
        XCTAssertEqual(kwargs?["enable_thinking"] as? Bool, true)
        XCTAssertEqual(kwargs?["preserve_thinking"] as? Bool, false)
        XCTAssertEqual(kwargs?["verification"] as? Bool, true)
        XCTAssertEqual(kwargs?["custom_flag"] as? Bool, true)
        XCTAssertEqual(kwargs?["level"] as? Int, 3)
    }

    func testWithoutModelSettingsProfileAndServerDefaultApply() {
        var profile = EndpointProfile.omlxLocal()
        profile.model = "unbekanntes-modell"
        profile.params.temperature = 0.4
        let payload = ChatRequestBuilder(profile: profile).payload(messages: [["role": "user", "content": "x"]], purpose: .chat, stream: true)
        XCTAssertEqual(payload["temperature"] as? Double, 0.4)
        XCTAssertNil(payload["reasoning_effort"])
        XCTAssertNil((payload["chat_template_kwargs"] as? [String: Any])?["verification"])
    }

    @MainActor
    func testOldThinkingSettingsMoveToModel() throws {
        var profile = EndpointProfile.omlxLocal()
        profile.model = "Qwen3.6-35B-A3B-oQ4e-fp16-mtp"
        profile.thinkingMode = .on
        profile.thinkingBudget = 4_096
        var stored = PersistedSettings.defaults
        stored.profiles = [profile]
        stored.preserveThinking = false
        stored.modelSettingsMigrated = false

        let entry = ChatViewModel.migratedModelSettings(from: stored)[ModelSettings.key(for: profile.model)]
        XCTAssertEqual(entry?.thinking, .on)
        XCTAssertEqual(entry?.thinkingBudget, 4_096)
        XCTAssertEqual(entry?.preserveThinking, false)
    }

    func testNonStreamedCompletionBecomesEvents() throws {
        let body = #"{"choices":[{"message":{"role":"assistant","reasoning_content":"erst denken","content":"Antwort","tool_calls":[{"id":"a","type":"function","function":{"name":"web_search","arguments":"{\"query\":\"x\"}"}},{"id":"b","type":"function","function":{"name":"python","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#
        var parser = StreamEventParser(format: .sse)
        let events = try parser.consume(completion: Data(body.utf8))
        let calls = events.compactMap { if case .toolCall(let c) = $0 { return c } else { return nil } }
        XCTAssertEqual(calls.map(\.name), ["web_search", "python"])
        XCTAssertEqual(calls.map(\.index), [0, 1], "Ohne Stream bekommen Tool-Calls ihre Position als Index")
        XCTAssertTrue(events.contains(.thinking("erst denken")))
        XCTAssertTrue(events.contains(.content("Antwort")))
        XCTAssertEqual(events.last, .done)
    }

    func testStreamingAndVisionAreStoredPerModel() throws {
        var settings = ModelSettings()
        settings.streaming = false
        settings.vision = false
        let decoded = try JSONDecoder().decode(ModelSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.streaming, false)
        XCTAssertEqual(decoded.vision, false)
        XCTAssertFalse(decoded.isEmpty)
    }

    func testBackgroundSystemPromptIsNotEmpty() {
        // Sage-A1.5 mit Verification verlangt eine System-Nachricht – auch bei Hintergrund-Aufträgen.
        XCTAssertFalse(ChatViewModel.backgroundSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
