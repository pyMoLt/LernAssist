import XCTest

/// UI-Tests laufen mit eigener Datenablage (`LERNASSIST_DATA_DIR`), nie mit den echten Chats.
final class LernassistUITests: XCTestCase {

    private var dataDir: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LernAssistUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dataDir)
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LERNASSIST_DATA_DIR"] = dataDir.path
        app.launch()
        return app
    }

    @MainActor
    func testLaunchShowsApp() throws {
        let app = launchApp()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }
}
