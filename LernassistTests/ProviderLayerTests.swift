import XCTest
@testable import Lernassist

/// Tests der Provider-Schicht (Phase 1): Stream-Parser, Adapter und LLMClient gegen einen Stub-Server.
final class ProviderLayerTests: XCTestCase {

    // MARK: StreamEventParser – SSE

    private func parse(_ lines: [String], format: StreamWireFormat = .sse) throws -> [LLMEvent] {
        var parser = StreamEventParser(format: format)
        var events: [LLMEvent] = []
        for line in lines { events += try parser.consume(line: line) }
        events += parser.flush()
        return events
    }

    private func text(_ events: [LLMEvent]) -> (content: String, thinking: String) {
        var c = "", t = ""
        for e in events {
            if case .content(let s) = e { c += s }
            if case .thinking(let s) = e { t += s }
        }
        return (c, t)
    }

    func testThinkTagsSplitAcrossChunks() throws {
        let events = try parse([
            #"data: {"choices":[{"delta":{"content":"<thi"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"nk>Überlege</th"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"ink>Antwort"}}]}"#,
            "data: [DONE]",
        ])
        XCTAssertEqual(text(events).thinking, "Überlege")
        XCTAssertEqual(text(events).content, "Antwort")
        XCTAssertEqual(events.last, .done)
    }

    func testReasoningContentField() throws {
        let events = try parse([
            #"data: {"choices":[{"delta":{"reasoning_content":"denke"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"fertig"}}]}"#,
        ])
        XCTAssertEqual(text(events).thinking, "denke")
        XCTAssertEqual(text(events).content, "fertig")
    }

    func testToolCallDeltasAndUsageChunkWithEmptyChoices() throws {
        let events = try parse([
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"web_search","arguments":"{\"qu"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ery\":\"x\"}"}}]}}]}"#,
            #"data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}"#,
        ])
        let calls = events.compactMap { e -> ToolCallInfo? in if case .toolCall(let c) = e { return c }; return nil }
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].name, "web_search")
        XCTAssertEqual(calls.map(\.arguments).joined(), #"{"query":"x"}"#)
        XCTAssertTrue(events.contains { if case .metrics(let m) = $0 { return m.completionTokens == 5 }; return false })
    }

    func testCommentsAndEventLinesAreIgnored() throws {
        let events = try parse([": keep-alive", "event: message", #"data: {"choices":[{"delta":{"content":"a"}}]}"#])
        XCTAssertEqual(text(events).content, "a")
    }

    func testServerErrorInsideStreamThrows() {
        var parser = StreamEventParser(format: .sse)
        XCTAssertThrowsError(try parser.consume(line: #"data: {"error":{"message":"context length exceeded"}}"#)) { error in
            XCTAssertEqual((error as? StreamServerError)?.message, "context length exceeded")
        }
    }

    func testUnclosedThinkIsFlushedAsThinking() throws {
        let events = try parse([#"data: {"choices":[{"delta":{"content":"<think>nur gedacht <"}}]}"#])
        XCTAssertEqual(text(events).thinking, "nur gedacht <")
    }

    // MARK: NDJSON (Ollama)

    func testNDJSONWithDoneFlag() throws {
        let events = try parse([
            #"{"message":{"role":"assistant","content":"Hal"},"done":false}"#,
            #"{"message":{"role":"assistant","content":"lo","thinking":"t"},"done":false}"#,
            #"{"message":{"role":"assistant","content":""},"done":true,"eval_count":2}"#,
        ], format: .ndjson)
        XCTAssertEqual(text(events).content, "Hallo")
        XCTAssertEqual(text(events).thinking, "t")
        XCTAssertEqual(events.last, .done)
    }

    // MARK: Fehlermeldungen

    func testServerMessageFormats() {
        XCTAssertEqual(LLMClient.serverMessage(fromBody: #"{"detail":"Model not found: x"}"#), "Model not found: x")
        XCTAssertEqual(LLMClient.serverMessage(fromBody: #"{"error":{"message":"Invalid API key"}}"#), "Invalid API key")
        XCTAssertEqual(LLMClient.serverMessage(fromBody: #"{"error":"busy"}"#), "busy")
        XCTAssertNil(LLMClient.serverMessage(fromBody: "<html><body>502</body></html>"))
        XCTAssertNil(LLMClient.serverMessage(fromBody: "  "))
    }

    func testHTTPErrorDescriptionIncludesServerMessage() {
        let error = EndpointManager.EndpointError.httpError(404, message: "Model not found")
        XCTAssertEqual(error.localizedDescription, "HTTP-Fehler 404: Model not found")
    }

    // MARK: Adapter

    func testOllamaAdapterConvertsOpenAIImageParts() {
        let message = EndpointManager.userImageMessage(text: "Was ist das?", base64: "QUJD", provider: .ollama)
        let adapted = OllamaAdapter().adapt(payload: ["messages": [message], "stream_options": ["include_usage": true]])
        XCTAssertNil(adapted["stream_options"])
        let converted = (adapted["messages"] as? [[String: Any]])?.first
        XCTAssertEqual(converted?["content"] as? String, "Was ist das?")
        XCTAssertEqual(converted?["images"] as? [String], ["QUJD"])
    }

    func testContextWindowReadsMaxModelLen() {
        let models = OpenAICompatibleAdapter().parseModels(["data": [["id": "qwen", "max_model_len": 262_144]]])
        XCTAssertEqual(models, [ProviderModel(id: "qwen", contextWindow: 262_144)])
    }

    func testURLsPerProvider() {
        XCTAssertEqual(OllamaAdapter().chatURL(base: "http://h:11434")?.absoluteString, "http://h:11434/api/chat")
        XCTAssertEqual(LMStudioNativeAdapter().chatURL(base: "http://h:1234")?.absoluteString, "http://h:1234/api/v0/chat/completions")
        XCTAssertEqual(OpenAICompatibleAdapter().chatURL(base: "http://h")?.absoluteString, "http://h/v1/chat/completions")
    }

    // MARK: ChatRequestBuilder

    func testEmptyBackgroundModelFallsBackToMainModel() {
        var profile = EndpointProfile(name: "p", baseURL: "http://h", model: "qwen3.6-35b")
        let builder = ChatRequestBuilder(profile: profile)
        XCTAssertEqual(builder.model(for: .background(useBackgroundModel: true, disableThinking: false)), "qwen3.6-35b")
        profile.backgroundJobModel = "qwen3.5-4b"
        XCTAssertEqual(ChatRequestBuilder(profile: profile).model(for: .background(useBackgroundModel: true, disableThinking: false)), "qwen3.5-4b")
        XCTAssertEqual(ChatRequestBuilder(profile: profile).model(for: .chat), "qwen3.6-35b")
    }

    func testChatPayloadCarriesParamsAndTools() {
        var profile = EndpointProfile(name: "p", baseURL: "http://h", model: "m")
        profile.params.temperature = 0.6
        profile.params.topK = 20
        let payload = ChatRequestBuilder(profile: profile).payload(
            messages: [["role": "user", "content": "x"]], purpose: .chat, stream: true,
            tools: [["type": "function"]])
        XCTAssertEqual(payload["temperature"] as? Double, 0.6)
        XCTAssertEqual(payload["top_k"] as? Int, 20)
        XCTAssertEqual(payload["tool_choice"] as? String, "auto")
        XCTAssertNotNil(payload["stream_options"])
    }

    func testBackgroundPayloadDisablesThinkingWithoutTools() {
        let profile = EndpointProfile(name: "p", baseURL: "http://h", model: "m")
        let payload = ChatRequestBuilder(profile: profile).payload(
            messages: [], purpose: .background(useBackgroundModel: false, disableThinking: true),
            stream: false, tools: [["type": "function"]], maxTokens: 900)
        XCTAssertNil(payload["tools"])
        XCTAssertNil(payload["stream_options"])
        XCTAssertEqual(payload["max_tokens"] as? Int, 900)
        XCTAssertEqual((payload["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], false)
    }

    func testNonStreamingRequestGetsLongerTimeout() throws {
        var profile = EndpointProfile(name: "p", baseURL: "http://h:8072", model: "m")
        profile.isRemote = true
        let builder = ChatRequestBuilder(profile: profile)
        XCTAssertEqual(try builder.urlRequest(payload: [:], stream: true).timeoutInterval, 300)
        XCTAssertEqual(try builder.urlRequest(payload: [:], stream: false).timeoutInterval, 600)
    }

    // MARK: LLMClient gegen Stub-Server

    private func stubSession(status: Int, body: String) -> URLSession {
        StubURLProtocol.response = (status, Data(body.utf8))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testClientStreamsEvents() async throws {
        let body = """
        data: {"choices":[{"delta":{"content":"Hallo "}}]}

        data: {"choices":[{"delta":{"content":"Welt"}}]}

        data: [DONE]

        """
        let session = stubSession(status: 200, body: body)
        var content = ""
        var sawDone = false
        for try await event in LLMClient.stream(URLRequest(url: URL(string: "http://stub/v1/chat/completions")!),
                                                format: .sse, session: session) {
            if case .content(let c) = event { content += c }
            if event == .done { sawDone = true }
        }
        XCTAssertEqual(content, "Hallo Welt")
        XCTAssertTrue(sawDone)
    }

    func testClientReportsHTTPErrorWithServerMessage() async {
        let session = stubSession(status: 401, body: #"{"detail":"Invalid API key"}"#)
        do {
            for try await _ in LLMClient.stream(URLRequest(url: URL(string: "http://stub/x")!), format: .sse, session: session) {}
            XCTFail("Fehler erwartet")
        } catch let EndpointManager.EndpointError.httpError(code, message) {
            XCTAssertEqual(code, 401)
            XCTAssertEqual(message, "Invalid API key")
        } catch {
            XCTFail("Falscher Fehler: \(error)")
        }
    }

    func testClientEmitsDoneWhenServerClosesWithoutSentinel() async throws {
        let session = stubSession(status: 200, body: #"data: {"choices":[{"delta":{"content":"x"}}]}"# + "\n")
        var events: [LLMEvent] = []
        for try await event in LLMClient.stream(URLRequest(url: URL(string: "http://stub/x")!), format: .sse, session: session) {
            events.append(event)
        }
        XCTAssertEqual(events, [.content("x"), .done])
    }
}

/// Minimaler URLProtocol-Stub: liefert für jede Anfrage dieselbe Antwort.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var response: (status: Int, body: Data) = (200, Data())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.response
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// oMLX-Anbieter (Phase 2).
final class OMLXProviderTests: XCTestCase {

    func testLegacyOMLXPresetMigratesToOMLXProvider() throws {
        let legacy = #"{"id":"0893A3C4-A941-4F5C-BF10-CC643E1F7DC3","name":"OMLX (lokal)","baseURL":"http://127.0.0.1:8072/v1","apiKey":"","model":"m","params":{},"isRemote":false,"provider":"openai_compat"}"#
        let profile = try JSONDecoder().decode(EndpointProfile.self, from: Data(legacy.utf8))
        XCTAssertEqual(profile.provider, .omlx)
        XCTAssertEqual(profile.thinkingMode, .serverDefault)
    }

    func testOtherOpenAIProfilesStayUntouched() throws {
        let json = #"{"id":"0893A3C4-A941-4F5C-BF10-CC643E1F7DC3","name":"llama","baseURL":"http://localhost:8080","apiKey":"","model":"m","params":{},"isRemote":false,"provider":"openai_compat"}"#
        XCTAssertEqual(try JSONDecoder().decode(EndpointProfile.self, from: Data(json.utf8)).provider, .openAICompatible)
    }

    func testTemplates() {
        let local = EndpointProfile.omlxLocal()
        XCTAssertEqual(local.provider, .omlx)
        XCTAssertFalse(local.isRemote)
        XCTAssertEqual(local.backgroundJobModel, "", "Hintergrund-Jobs nutzen standardmäßig das Hauptmodell")
        XCTAssertEqual(EndpointManager.chatCompletionsURL(for: local)?.absoluteString, "http://127.0.0.1:8072/v1/chat/completions")

        let remote = EndpointProfile.omlxRemote()
        XCTAssertTrue(remote.isRemote)
        XCTAssertEqual(remote.baseURL, "http://macbook-pro:8072")
        XCTAssertEqual(remote.effectiveRequestTimeout, 300)
        XCTAssertEqual(remote.thinkingMode, .on)
    }

    func testThinkingOnSendsBudgetOnlyToOMLX() {
        var profile = EndpointProfile.omlxLocal()
        profile.thinkingBudget = 2_048
        let omlx = ChatRequestBuilder(profile: profile).payload(messages: [], purpose: .chat, stream: true)
        XCTAssertEqual((omlx["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], true)
        XCTAssertEqual(omlx["thinking_budget"] as? Int, 2_048)
        XCTAssertNil(omlx["think"], "oMLX bekommt kein Ollama-Feld")

        profile.provider = .openAICompatible
        let openAI = ChatRequestBuilder(profile: profile).payload(messages: [], purpose: .chat, stream: true)
        XCTAssertNil(openAI["thinking_budget"])
        XCTAssertNil(openAI["think"])
    }

    func testThinkingOffDropsBudgetForOMLX() {
        var profile = EndpointProfile.omlxLocal()
        profile.thinkingMode = .off
        let payload = ChatRequestBuilder(profile: profile).payload(messages: [], purpose: .chat, stream: true)
        XCTAssertEqual((payload["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], false)
        XCTAssertNil(payload["thinking_budget"])
    }

    func testOMLXUsageMetrics() {
        let metrics = MetricsParser.parse(fromDict: ["usage": [
            "prompt_tokens": 100, "completion_tokens": 50,
            "generation_tokens_per_second": 61.5, "time_to_first_token": 0.8,
        ]])
        XCTAssertEqual(metrics?.tokensPerSecond, 61.5)
        XCTAssertEqual(metrics?.timeToFirstToken, 0.8)
    }

    func testOMLXStatusParsingDetectsVision() {
        let models = OMLXAdapter().parseStatus(["models": [
            ["id": "Qwen3.6-35B-A3B-oQ4e-mtp", "model_type": "vlm", "loaded": true, "max_context_window": 262_144],
            ["id": "Qwen3-Reranker-0.6B-8bit-mlx", "model_type": "reranker", "loaded": false],
        ]])
        XCTAssertEqual(models.first(where: { $0.id.hasPrefix("Qwen3.6") })?.supportsVision, true)
        XCTAssertEqual(models.first(where: { $0.id.hasPrefix("Qwen3.6") })?.contextWindow, 262_144)
        XCTAssertEqual(models.first(where: { $0.id.contains("Reranker") })?.supportsVision, false)
    }

    func testLoadURLEncodesModelId() {
        XCTAssertEqual(OMLXAdapter().loadURL(base: "http://h:8072", model: "a/b c")?.absoluteString,
                       "http://h:8072/v1/models/a%2Fb%20c/load")
    }

    @MainActor
    func testLMStudioManagerIgnoresOMLXAndOtherLocalServers() {
        let manager = LMStudioModelManager.shared
        XCTAssertFalse(manager.isLMStudioLocal(profile: EndpointProfile.omlxLocal()))
        XCTAssertFalse(manager.isLMStudioLocal(profile: EndpointProfile(name: "l", baseURL: "http://localhost:8080")))
        XCTAssertTrue(manager.isLMStudioLocal(profile: EndpointProfile(name: "l", baseURL: "http://127.0.0.1:1234/v1")))
    }
}
