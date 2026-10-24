import XCTest
@testable import Lernassist

/// Interaktive Ausgaben (Version 4): lokale Bibliotheken, Härtung, Auto-Korrektur, Probelauf.
@MainActor
final class HTMLArtifactTests: XCTestCase {

    func testKnownCDNLibrariesAreReplacedLocally() {
        let html = """
        <html><head>
        <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js" integrity="sha384-abc" crossorigin="anonymous"></script>
        <script src="https://d3js.org/d3.v7.min.js"></script>
        <script src="https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js"></script>
        <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css">
        <link href="https://fonts.googleapis.com/css2?family=Inter&display=swap" rel="stylesheet">
        <script src="https://cdn.tailwindcss.com"></script>
        </head><body></body></html>
        """
        let rewrite = HTMLLibraries.rewrite(html)
        XCTAssertTrue(rewrite.unknownHosts.isEmpty, "\(rewrite.unknownHosts)")
        XCTAssertTrue(rewrite.html.contains("lernassist-lib://lib/lib-chart.umd.min.js"))
        XCTAssertTrue(rewrite.html.contains("lernassist-lib://lib/lib-d3.min.js"))
        XCTAssertTrue(rewrite.html.contains("lernassist-lib://lib/lib-three.min.js"))
        XCTAssertTrue(rewrite.html.contains("lernassist-lib://lib/css/lib-fontawesome-all.min.css"))
        XCTAssertTrue(rewrite.html.contains("lernassist-lib://lib/lib-tailwind.js"))
        XCTAssertFalse(rewrite.html.contains("fonts.googleapis"), "Google Fonts fliegt raus")
        XCTAssertFalse(rewrite.html.contains("integrity"), "SRI passt nicht zur lokalen Kopie")
        XCTAssertFalse(rewrite.html.contains("crossorigin"))
    }

    func testUnknownAndOldVersionsNeedPermission() {
        let html = """
        <script src="https://cdn.plot.ly/plotly-2.27.0.min.js"></script>
        <script src="https://d3js.org/d3.v3.min.js"></script>
        <script type="module">import * as THREE from "https://unpkg.com/three@0.160.0/build/three.module.js";</script>
        <img src="https://upload.wikimedia.org/x.png">
        """
        let rewrite = HTMLLibraries.rewrite(html)
        XCTAssertEqual(Set(rewrite.unknownHosts), ["cdn.plot.ly", "d3js.org", "unpkg.com", "upload.wikimedia.org"])
    }

    func testCSPAllowsLocalLibrariesAndOnlyGrantedHosts() {
        let csp = HTMLArtifactRuntime.contentSecurityPolicy(allowedHosts: ["cdn.plot.ly"])
        XCTAssertTrue(csp.contains("script-src 'unsafe-inline' 'unsafe-eval' lernassist-lib: https://cdn.plot.ly"))
        XCTAssertTrue(csp.contains("connect-src 'none'"), "Netzabfragen bleiben gesperrt")
        XCTAssertFalse(HTMLArtifactRuntime.contentSecurityPolicy(allowedHosts: []).contains("https://"))
    }

    func testHeadScriptsMoveToBodyEnd() throws {
        let html = "<html><head><script src=\"x.js\"></script><script>document.getElementById('b').onclick = f;</script></head><body><button id=\"b\">B</button></body></html>"
        let moved = try XCTUnwrap(HTMLArtifactRuntime.moveHeadScriptsToBodyEnd(html))
        XCTAssertTrue(moved.contains("<head><script src=\"x.js\"></script></head>"), "externe Skripte bleiben im Kopf")
        XCTAssertTrue(moved.hasSuffix("<script>document.getElementById('b').onclick = f;</script>\n</body></html>"))
        XCTAssertNil(HTMLArtifactRuntime.moveHeadScriptsToBodyEnd("<html><head><title>x</title></head><body></body></html>"))
    }

    func testPreflightReportsSyntaxErrors() async {
        let errors = await HTMLPreflight.errors(in: "<html><body><script>let x = ;</script></body></html>", allowedHosts: [])
        XCTAssertFalse(errors.isEmpty)
        XCTAssertTrue(errors.joined().contains("Zeile"), "\(errors)")
    }

    func testPreflightCleanPageAndLocalLibrary() async {
        let html = """
        <html><head><script src="https://cdn.jsdelivr.net/npm/chart.js"></script></head>
        <body><canvas id="c"></canvas><script>if (typeof Chart === 'undefined') { throw new Error('Chart fehlt'); }</script></body></html>
        """
        let errors = await HTMLPreflight.errors(in: html, allowedHosts: [])
        XCTAssertEqual(errors, [])
    }

    func testPreflightDetectsEarlyDOMAccessAndFixWorks() async throws {
        let html = "<html><head><script>document.getElementById('b').addEventListener('click', function(){});</script></head><body><button id=\"b\">B</button></body></html>"
        let errors = await HTMLPreflight.errors(in: html, allowedHosts: [])
        XCTAssertTrue(HTMLArtifactRuntime.looksLikeEarlyDOMAccess(errors), "\(errors)")
        let fixed = try XCTUnwrap(HTMLArtifactRuntime.moveHeadScriptsToBodyEnd(html))
        let after = await HTMLPreflight.errors(in: fixed, allowedHosts: [])
        XCTAssertEqual(after, [])
    }
}
