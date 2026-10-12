import XCTest
import AppKit
@testable import Lernassist

/// Live-Tests gegen echte Dienste. Laufen nur mit `TEST_RUNNER_LERNASSIST_LIVE=1 xcodebuild test …`
/// (sonst übersprungen), damit normale Testläufe kein Netz brauchen.
/// Optional: `TEST_RUNNER_LERNASSIST_SEARXNG=<url>` und `TEST_RUNNER_LERNASSIST_OMLX=<baseURL>`.
final class LiveResearchTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var outDir: URL {
        URL(fileURLWithPath: env["LERNASSIST_LIVE_OUT"] ?? NSTemporaryDirectory())
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(env["LERNASSIST_LIVE"] == "1", "Live-Tests nur mit LERNASSIST_LIVE=1")
    }

    private func save(_ name: String, _ text: String) {
        try? text.write(to: outDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testWikipediaLive() async throws {
        let hits = try await WikipediaSource(language: "de").search("Citratzyklus", limit: 3)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertGreaterThan(hits.first?.blocks?.count ?? 0, 10, "Volltext über die API")
        save("live-wikipedia.txt", hits.first?.blocks?.prefix(15).joined(separator: "\n") ?? "")
    }

    func testEuropePMCLive() async throws {
        let hits = try await EuropePMCSource().search("metformin lactic acidosis", limit: 3)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.allSatisfy { ($0.blocks?.count ?? 0) >= 2 })
        save("live-europepmc.txt", hits.map { "\($0.title)\n\($0.url)\n\($0.blocks?.joined(separator: "\n") ?? "")" }.joined(separator: "\n\n"))
    }

    func testArxivLive() async throws {
        let hits = try await ArxivSource().search("protein folding transformer", limit: 3)
        XCTAssertFalse(hits.isEmpty)
        save("live-arxiv.txt", hits.map { "\($0.title) \($0.url)" }.joined(separator: "\n"))
    }

    func testStackExchangeLive() async throws {
        let hits = try await StackExchangeSource(sites: ["stackoverflow"]).search("swift async await cancellation", limit: 3)
        XCTAssertFalse(hits.isEmpty)
        save("live-stackexchange.txt", hits.map { "\($0.title)\n\($0.blocks?.joined(separator: "\n") ?? "")" }.joined(separator: "\n\n"))
    }

    func testExaLive() async throws {
        let hits = try await ExaSource().search("Krebs-Zyklus Biochemie", limit: 3)
        XCTAssertFalse(hits.isEmpty)
        save("live-exa.txt", hits.map { "\($0.title)\n\($0.url)\n\($0.blocks?.joined(separator: "\n") ?? "")" }.joined(separator: "\n\n"))
    }

    func testExtractionOfRealPages() async throws {
        var report = ""
        for raw in ["https://flexikon.doccheck.com/de/Citratzyklus",
                    "https://www.spektrum.de/lexikon/biologie/citratzyklus/14496",
                    "https://de.wikipedia.org/wiki/Glykolyse"] {
            let url = URL(string: raw)!
            do {
                let page = try await WebFetcher().fetch(url)
                let doc = try ContentExtractor.extract(page)
                report += "=== \(raw) (\(doc.characterCount) Zeichen, Bot: \(ContentExtractor.looksLikeBotPage(doc)))\n"
                report += doc.blocks.prefix(12).joined(separator: "\n") + "\n\n"
            } catch {
                report += "=== \(raw) FEHLER: \(error.localizedDescription)\n\n"
            }
        }
        save("live-extraction.txt", report)
        XCTAssertTrue(report.contains("Citrat"))
    }

    func testFullPipelineLive() async throws {
        var settings = ResearchSettings()
        var reranker: Reranker?
        if let omlx = env["LERNASSIST_OMLX"] {
            var profile = EndpointProfile.omlxLocal()
            profile.baseURL = omlx
            reranker = OMLXReranker(profile: profile, model: settings.rerankerModel)
        } else {
            settings.rerankerMode = .off
        }
        let pipeline = WebResearchPipeline(settings: settings, searxngURL: env["LERNASSIST_SEARXNG"] ?? "", reranker: reranker)
        let start = Date()
        let result = await pipeline.run("Regulation Citratzyklus Isocitrat-Dehydrogenase")
        let seconds = Date().timeIntervalSince(start)
        save("live-pipeline.txt", "Dauer: \(String(format: "%.1f", seconds)) s\nReranker: \(result.usedReranker)\nHinweise: \(result.notes)\n\n" + result.modelText)
        XCTAssertFalse(result.passages.isEmpty)
        XCTAssertLessThan(seconds, 45)
    }

    func testBlockedLocalURLInBrowseTool() async {
        let tool = BrowseURLTool()
        let result = await tool.run(arguments: #"{"url":"http://127.0.0.1:1234/v1/models"}"#, sessionID: nil)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("gesperrt"))
    }
}

/// Live: Coding-Sandbox mit echtem Python (nur mit LERNASSIST_LIVE=1).
@MainActor
final class LiveSandboxTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LERNASSIST_LIVE"] == "1")
    }

    func testPlotErrorAndReadBlock() async throws {
        let tool = CodingTool()
        let plot = await tool.run(arguments: #"{"language":"python","code":"import matplotlib.pyplot as plt\nimport numpy as np\nx=np.linspace(0,6,50)\nplt.plot(x,np.sin(x))\nplt.title('Sinus')\nplt.show()\nprint('fertig')"}"#,
                                  sessionID: "live-test")
        XCTAssertFalse(plot.isError, plot.content)
        XCTAssertTrue(plot.content.contains("fertig"))
        XCTAssertEqual(plot.artifacts.count, 1, "Plot als Bild")

        let failing = await tool.run(arguments: #"{"language":"python","code":"a = 1\nb = 0\nprint(a / b)"}"#, sessionID: "live-test")
        XCTAssertTrue(failing.isError)
        XCTAssertTrue(failing.content.contains("→   3 | print(a / b)"), failing.content)

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let read = await tool.run(arguments: "{\"language\":\"python\",\"code\":\"print(open('\(home)/.zsh_history').read()[:20])\"}", sessionID: "live-test")
        XCTAssertTrue(read.isError)
        XCTAssertTrue(read.content.contains("PermissionError") || read.content.contains("Operation not permitted"), read.content)
    }
}

/// Live gegen oMLX (nur mit LERNASSIST_LIVE=1 und LERNASSIST_OMLX=<baseURL>).
final class LiveOMLXTests: XCTestCase {
    private var base: String { ProcessInfo.processInfo.environment["LERNASSIST_OMLX"] ?? "" }
    private var outDir: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["LERNASSIST_LIVE_OUT"] ?? NSTemporaryDirectory()) }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LERNASSIST_LIVE"] == "1" && !base.isEmpty)
    }

    private var profile: EndpointProfile {
        var p = EndpointProfile.omlxLocal()
        p.baseURL = base
        return p
    }

    func testModelsStatusAndDiagnosis() async throws {
        let models = try await EndpointManager.fetchProviderModels(for: profile)
        XCTAssertTrue(models.contains { $0.id == EndpointProfile.recommendedOMLXModel })
        XCTAssertNotNil(models.first { $0.id == EndpointProfile.recommendedOMLXModel }?.contextWindow, "max_model_len gelesen")

        let status = await EndpointDiagnostics.omlxStatus(profile)
        let report = status.map { "\($0.id) vision=\(String(describing: $0.supportsVision)) loaded=\(String(describing: $0.isLoaded)) ctx=\(String(describing: $0.contextWindow))" }
        try report.joined(separator: "\n").write(to: outDir.appendingPathComponent("live-omlx-status.txt"), atomically: true, encoding: .utf8)

        let diagnosis = await EndpointDiagnostics.diagnose(profile)
        XCTAssertEqual(diagnosis.status, .ok, diagnosis.message)
    }

    func testReranker() async throws {
        let reranker = OMLXReranker(profile: profile, model: ResearchSettings().rerankerModel, timeout: 60)
        let start = Date()
        let scores = try await reranker.scores(query: "Wo findet der Citratzyklus statt?",
                                               documents: ["Paris ist die Hauptstadt Frankreichs.",
                                                           "Der Citratzyklus läuft in der Matrix der Mitochondrien ab."])
        let elapsed = Date().timeIntervalSince(start)
        try "Scores: \(scores), Dauer \(elapsed) s".write(to: outDir.appendingPathComponent("live-omlx-rerank.txt"), atomically: true, encoding: .utf8)
        XCTAssertGreaterThan(scores[1], scores[0])
    }

    func testStreamingChatWithThinking() async throws {
        var p = profile
        p.thinkingBudget = 512
        let builder = ChatRequestBuilder(profile: p)
        let payload = builder.payload(messages: [["role": "user", "content": "Nenne in einem Satz, wo der Citratzyklus stattfindet."]],
                                      purpose: .chat, stream: true)
        let request = try builder.urlRequest(payload: payload, stream: true)
        var content = "", thinking = ""
        var metrics: ChatMetrics?
        let start = Date()
        for try await event in LLMClient.stream(request, format: .sse) {
            switch event {
            case .content(let c): content += c
            case .thinking(let t): thinking += t
            case .metrics(let m): metrics = m
            default: break
            }
        }
        let report = "Dauer \(Date().timeIntervalSince(start)) s\nTPS \(String(describing: metrics?.tokensPerSecond)) TTFT \(String(describing: metrics?.timeToFirstToken))\nThinking (\(thinking.count) Zeichen): \(thinking.prefix(300))\n\nAntwort: \(content)"
        try report.write(to: outDir.appendingPathComponent("live-omlx-chat.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(content.lowercased().contains("mitochond"), content)
        XCTAssertFalse(content.contains("<think>"))
        XCTAssertNotNil(metrics?.tokensPerSecond)
    }

    func testVisionRequest() async throws {
        // Kleines PNG mit Text „ATP“ erzeugen und vom Modell lesen lassen.
        let image = NSImage(size: NSSize(width: 240, height: 100), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            ("ATP" as NSString).draw(at: NSPoint(x: 40, y: 20), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 56), .foregroundColor: NSColor.black])
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return XCTFail() }
        var p = profile
        p.thinkingMode = .off
        let builder = ChatRequestBuilder(profile: p)
        let message = EndpointManager.userImageMessage(text: "Welches Wort steht auf dem Bild? Antworte nur mit dem Wort.", base64: png.base64EncodedString(), provider: .omlx)
        let request = try builder.urlRequest(payload: builder.payload(messages: [message], purpose: .chat, stream: true), stream: true)
        var content = ""
        for try await event in LLMClient.stream(request, format: .sse) {
            if case .content(let c) = event { content += c }
        }
        XCTAssertTrue(content.uppercased().contains("ATP"), content)
    }
}

extension LiveOMLXTests {
    func testStructuredFlashcardsJSON() async throws {
        let builder = ChatRequestBuilder(profile: EndpointProfile.omlxLocal().with(baseURL: ProcessInfo.processInfo.environment["LERNASSIST_OMLX"] ?? ""))
        let schema: [String: Any] = ["type": "object",
            "properties": ["cards": ["type": "array", "items": ["type": "object",
                "properties": ["front": ["type": "string"], "back": ["type": "string"]],
                "required": ["front", "back"], "additionalProperties": false]]],
            "required": ["cards"], "additionalProperties": false]
        let payload = builder.payload(messages: [["role": "user", "content": "Erstelle 3 Karteikarten zum Citratzyklus."]],
                                      purpose: .background(useBackgroundModel: false, disableThinking: true),
                                      stream: false, jsonSchema: ("flashcards", schema))
        let text = try await LLMClient.complete(try builder.urlRequest(payload: payload, stream: false))
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        XCTAssertEqual((object?["cards"] as? [[String: Any]])?.count, 3, text)
    }
}

extension EndpointProfile {
    func with(baseURL: String) -> EndpointProfile { var p = self; p.baseURL = baseURL; return p }
}

/// Live: eigene Python-Umgebung einrichten und darin rechnen (nur mit LERNASSIST_LIVE=1).
@MainActor
final class LivePythonEnvironmentTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LERNASSIST_LIVE"] == "1")
    }

    func testInstallAndRunWithModernPython() async throws {
        let statuses = StatusLog()
        await PythonEnvironmentInstaller.shared.ensureInstalled { statuses.add($0) }
        XCTAssertTrue(PythonEnvironmentInstaller.isReady, statuses.all.map(\.label).joined(separator: "\n"))
        XCTAssertTrue(PythonEnvironmentInstaller.readyVersion?.hasPrefix("3.12") == true)

        let tool = CodingTool()
        let result = await tool.run(arguments: #"{"language":"python","code":"import sys, pandas as pd, scipy.stats as st\ndf = pd.DataFrame({'x':[1,2,3,4],'y':[2,4,5,8]})\nprint(sys.version.split()[0], round(st.pearsonr(df.x, df.y)[0], 3))"}"#,
                                    sessionID: "live-env")
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("3.12"), result.content)
        XCTAssertTrue(result.content.contains("0.98"), result.content)
    }
}

extension LivePythonEnvironmentTests {
    func testModelInstallsMissingPackage() async throws {
        try XCTSkipUnless(PythonEnvironmentInstaller.isReady)
        CodingEnvironment.shared.autoInstallPackages = true
        defer { CodingEnvironment.shared.autoInstallPackages = false }
        let result = await CodingTool().run(arguments: #"{"language":"python","install_packages":["tabulate"],"code":"from tabulate import tabulate\nprint(tabulate([[1,2]], headers=['a','b']))"}"#,
                                            sessionID: "live-env")
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("a    b") || result.content.contains("a  b"), result.content)
    }
}

final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [PythonEnvironmentStatus] = []
    func add(_ s: PythonEnvironmentStatus) { lock.withLock { items.append(s) } }
    var all: [PythonEnvironmentStatus] { lock.withLock { items } }
}

extension LiveResearchTests {
    @MainActor
    func testBrowsePDFWithFocus() async throws {
        let start = Date()
        let result = await BrowseURLTool().run(arguments: #"{"url":"https://www.leitlinien.de/themen/diabetes/kurzfassung/dm-vers3-0-kurz.pdf/@@download/file/diabetes-vers3-0-kurz.pdf","focus":"HbA1c Zielwert Therapieempfehlung"}"#, sessionID: nil)
        let elapsed = Date().timeIntervalSince(start)
        try? "Dauer \(elapsed)\n\(result.content.prefix(3000))".write(to: URL(fileURLWithPath: (ProcessInfo.processInfo.environment["LERNASSIST_LIVE_OUT"] ?? NSTemporaryDirectory()) + "/live-browse-pdf.txt"), atomically: true, encoding: .utf8)
        XCTAssertFalse(result.isError, result.content)
        XCTAssertLessThan(elapsed, 20)
    }
}
