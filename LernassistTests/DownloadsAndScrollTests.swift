import XCTest
@testable import Lernassist

/// Python-Downloads (Dateityp-Prüfung, ZIP-Inhalt, Dateinamen) und die Chat-Fassung von Bildern.
final class DownloadsAndScrollTests: XCTestCase {

    func testDataFormatsAreAllowedAndProgramsBlocked() {
        XCTAssertTrue(DataDownloader.classify(Data("time,temp\n0,12.5\n".utf8)).allowed)
        XCTAssertTrue(DataDownloader.classify(Data(#"{"hourly":{"temperature_2m":[1,2]}}"#.utf8)).allowed)
        XCTAssertEqual(DataDownloader.classify(Data("%PDF-1.7".utf8)).kind, "PDF")
        XCTAssertTrue(DataDownloader.classify(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])).allowed)

        XCTAssertFalse(DataDownloader.classify(Data([0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00])).allowed, "Mach-O")
        XCTAssertFalse(DataDownloader.classify(Data([0x4D, 0x5A, 0x90, 0x00])).allowed, "Windows-Programm")
        XCTAssertFalse(DataDownloader.classify(Data("#!/bin/sh\nrm -rf ~".utf8)).allowed, "Skript")
        XCTAssertFalse(DataDownloader.classify(Data("xar!....".utf8)).allowed, "Installer")
        XCTAssertFalse(DataDownloader.classify(Data([0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE])).allowed, "Unbekannte Binärdaten")
    }

    /// Minimaler ZIP-Eintrag (lokaler Header + Name, ohne Inhalt).
    private func zipEntry(_ name: String) -> Data {
        var bytes: [UInt8] = [0x50, 0x4B, 0x03, 0x04] + [UInt8](repeating: 0, count: 22)
        let nameBytes = Array(name.utf8)
        bytes += [UInt8(nameBytes.count & 0xFF), UInt8(nameBytes.count >> 8), 0, 0]
        bytes += nameBytes
        return Data(bytes)
    }

    func testZipWithProgramsIsBlocked() {
        XCTAssertNil(DataDownloader.blockedZipEntry(zipEntry("daten/wetter.csv") + zipEntry("liesmich.txt")))
        XCTAssertEqual(DataDownloader.blockedZipEntry(zipEntry("daten.csv") + zipEntry("install.sh")), ".sh")
        XCTAssertEqual(DataDownloader.blockedZipEntry(zipEntry("Tool.app/Contents/MacOS/Tool")), ".app")
    }

    func testSweepRemovesProgramsAndDisallowedArchives() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Date()
        try Data("a,b\n1,2\n".utf8).write(to: dir.appendingPathComponent("daten.csv"))
        try Data([0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00]).write(to: dir.appendingPathComponent("tool"))
        try Data("#!/bin/sh\necho hi".utf8).write(to: dir.appendingPathComponent("run.sh"))
        try zipEntry("daten.csv").write(to: dir.appendingPathComponent("paket.zip"))
        try Data("print('x')".utf8).write(to: dir.appendingPathComponent("script_v1.py"))

        let removed = DataDownloader.sweep(directory: dir, modifiedSince: start, keep: [], allowArchives: false)
        XCTAssertEqual(Set(removed.map(\.name)), ["tool", "run.sh", "paket.zip"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("daten.csv").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("script_v1.py").path))
    }

    func testOfficeFilesAreNotTreatedAsArchives() {
        XCTAssertTrue(DataDownloader.officeZip(zipEntry("[Content_Types].xml") + zipEntry("xl/workbook.xml")))
        XCTAssertFalse(DataDownloader.officeZip(zipEntry("daten.csv")))
    }

    func testDefaultDownloadTypes() {
        let mime = DownloadFileType.defaults.flatMap(\.mimePrefixes)
        XCTAssertTrue(mime.contains("application/pdf"))
        XCTAssertTrue(mime.contains("text/"))
        XCTAssertTrue(mime.contains("image/"))
        XCTAssertFalse(mime.contains("application/zip"), "Archive standardmäßig aus")
    }

    func testNetworkAttemptsGetTheDownloadsHint() {
        XCTAssertTrue(CodingTool.looksLikeNetworkAttempt("requests.exceptions.ConnectionError: Max retries exceeded"))
        XCTAssertFalse(CodingTool.looksLikeNetworkAttempt("ZeroDivisionError: division by zero"))
    }

    func testPreludeChecksContentTypes() {
        XCTAssertTrue(CodingEnvironment.pythonPrelude.contains("LERNASSIST_ALLOWED_MIME"))
    }

    func testChatImagesAreShownDownsampled() {
        let big = NSImage(size: NSSize(width: 3_000, height: 2_000))
        big.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 3_000, height: 2_000).fill()
        big.unlockFocus()
        let shown = OptimizedImageView.displayVersion(of: big)
        let cg = shown.cgImage(forProposedRect: nil, context: nil, hints: nil)
        XCTAssertLessThanOrEqual(CGFloat(max(cg?.width ?? 0, cg?.height ?? 0)), OptimizedImageView.displayMaxPixels)
        XCTAssertEqual(shown.size, big.size, "Punktgröße und Seitenverhältnis bleiben gleich")
    }
}

final class PythonProxyClockTests: XCTestCase {
    /// Ein offener Freigabe-Dialog hält die Uhr sofort an – nicht erst nach dem Klick.
    func testOpenDialogPausesTheClockImmediately() async throws {
        let gate = AsyncGate()
        let proxy = PythonNetworkProxy(policy: .init(maxConnections: 5, maxBytesPerConnection: 1_000_000),
                                       permission: { _ in await gate.wait(); return false })
        let port = try await proxy.start()
        defer { proxy.stop() }
        // CONNECT an den Proxy schicken; die Freigabe bleibt offen, bis das Gate aufgeht.
        let socket = try await TCPProbe.connect(port: port, payload: "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com\r\n\r\n")
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertGreaterThan(proxy.waitingTime, 0.8, "Wartezeit zählt schon während der Dialog offen ist")
        await gate.open()
        socket.cancel()
    }
}

actor AsyncGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

import Network
enum TCPProbe {
    static func connect(port: UInt16, payload: String) async throws -> NWConnection {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: .global())
        connection.send(content: Data(payload.utf8), completion: .contentProcessed { _ in })
        return connection
    }
}
