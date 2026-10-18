import XCTest
import AppKit
@testable import Lernassist

/// Abbildungen aus der Recherche: Filter, Extraktion, chatweite Nummern, Einbettung, Live-Recherche.
final class ResearchImagesTests: XCTestCase {

    private func image(_ url: String, caption: String = "", alt: String = "", width: Int? = nil) -> PageImage {
        PageImage(url: url, pageURL: "https://example.org/seite", caption: caption, alt: alt, width: width)
    }

    func testCandidateFilter() {
        XCTAssertTrue(ResearchImages.isCandidate(image("https://upload.wikimedia.org/x/500px-Glycolysis.svg.png",
                                                      caption: "Ablauf der Glykolyse mit allen Enzymen")))
        XCTAssertTrue(ResearchImages.isCandidate(image("https://example.org/img/schema.jpg", alt: "Schema der Atmungskette in der Mitochondrienmembran")))
        XCTAssertFalse(ResearchImages.isCandidate(image("http://example.org/a.jpg", caption: "Ablauf der Glykolyse mit Enzymen")), "nur https")
        XCTAssertFalse(ResearchImages.isCandidate(image("https://example.org/logo.png", caption: "Das Logo der Universität Heidelberg")))
        XCTAssertFalse(ResearchImages.isCandidate(image("https://example.org/a.svg", caption: "Ablauf der Glykolyse mit Enzymen")), "SVG nur als PNG")
        XCTAssertFalse(ResearchImages.isCandidate(image("https://example.org/a.jpg", alt: "Bild")), "kein aussagekräftiger Text")
        XCTAssertFalse(ResearchImages.isCandidate(image("https://example.org/a.jpg", alt: "DSC_0042.jpg")), "Dateiname ist kein Alt-Text")
        XCTAssertFalse(ResearchImages.isMeaningful("Bild zum Beitrag"))
        XCTAssertFalse(ResearchImages.isMeaningful("Symbolbild"))
        XCTAssertFalse(ResearchImages.isMeaningful("Featured image for the post"))
        XCTAssertTrue(ResearchImages.isMeaningful("Bildung von Pyruvat aus Phosphoenolpyruvat durch die Pyruvatkinase"))
        XCTAssertFalse(ResearchImages.isCandidate(image("https://example.org/a.jpg", caption: "Ablauf der Glykolyse mit Enzymen", width: 80)), "zu klein")
        XCTAssertFalse(ResearchImages.isCandidate(image("https://localhost/a.jpg", caption: "Ablauf der Glykolyse mit Enzymen")))
    }

    func testPageImagesFromFiguresAndAltText() {
        let html = """
        <html><body><article>
        <h1>Glykolyse</h1><p>\(String(repeating: "Die Glykolyse ist der Abbau von Glucose zu Pyruvat. ", count: 12))</p>
        <figure><img src="/bilder/glykolyse.png" width="640" height="480"><figcaption>Übersicht der Glykolyse mit den zehn Enzymschritten</figcaption></figure>
        <img srcset="/a-320.jpg 320w, /a-960.jpg 960w" src="/a-320.jpg" alt="Elektronenmikroskopische Aufnahme eines Mitochondriums">
        <img src="data:image/png;base64,AAAA" alt="Platzhalter">
        </article></body></html>
        """
        let doc = ContentExtractor.extractHTML(html, url: "https://example.org/artikel")
        XCTAssertEqual(doc.images.count, 2)
        XCTAssertEqual(doc.images.first?.url, "https://example.org/bilder/glykolyse.png")
        XCTAssertEqual(doc.images.first?.caption, "Übersicht der Glykolyse mit den zehn Enzymschritten")
        XCTAssertEqual(doc.images.last?.url, "https://example.org/a-960.jpg", "größte Fassung aus srcset")
    }

    func testImagesMustMatchTheTopic() async {
        XCTAssertEqual(ResearchImages.textQuery("Herz Aufbau Anatomie Schemazeichnung"), "Herz Aufbau Anatomie")
        let muscle = (image: image("https://u.org/m.png", caption: "Schematischer Aufbau eines Skelettmuskels"), pageTitle: "Skelettmuskel")
        let heart = (image: image("https://u.org/h.png", caption: "Längsschnitt durch das Herz mit Vorhöfen und Kammern"), pageTitle: "Herz")
        let picked = await ResearchImages.rank([muscle, heart], query: "Herz Aufbau Anatomie Schemazeichnung", reranker: nil)
        XCTAssertEqual(picked.map(\.url), ["https://u.org/h.png"])
    }

    @MainActor
    func testImageNumbersRunAcrossTheChat() {
        func ref(_ n: Int, _ url: String) -> ResearchImageRef {
            ResearchImageRef(number: n, imageID: UUID(), caption: "Abb \(n)", sourceURL: url, pageURL: "https://p.org", domain: "p.org")
        }
        var earlier = ToolCallInfo(id: "a", index: 0, name: "web_search", arguments: "{}", result: "[B1] Abbildung: A — p.org")
        earlier.researchImages = [ref(1, "https://img.org/a.png")]
        var next = ToolCallInfo(id: "b", index: 0, name: "web_search", arguments: "{}",
                                result: "Abbildungen:\n[B1] Abbildung: C — p.org\n[B2] Abbildung: A — p.org")
        next.researchImages = [ref(1, "https://img.org/c.png"), ref(2, "https://img.org/a.png")]
        let renumbered = ChatViewModel.renumberCitations(in: [next], after: [earlier])[0]
        XCTAssertEqual(renumbered.researchImages?.map(\.number), [2, 1], "neues Bild zählt weiter, bekanntes behält seine Nummer")
        XCTAssertTrue(renumbered.result?.contains("[B2] Abbildung: C") == true)
        XCTAssertTrue(renumbered.result?.contains("[B1] Abbildung: A") == true)
    }

    func testImagesAreEmbeddedOnlyOnTheirOwnLine() {
        let id = UUID()
        let images = [3: ResearchImageRef(number: 3, imageID: id, caption: "Ablauf der Glykolyse", sourceURL: "https://u.org/g.png",
                                          pageURL: "https://de.wikipedia.org/wiki/Glykolyse", domain: "de.wikipedia.org")]
        let markdown = "Die Glykolyse läuft im Zytosol ab.\n\n[B3]\n\nWie in [B3] zu sehen …\n```\n[B3]\n```"
        let result = ChatViewModel.embedResearchImages(in: markdown, images: images)
        XCTAssertTrue(result.contains("![Ablauf der Glykolyse](lernassist-image://\(id.uuidString))"))
        XCTAssertTrue(result.contains("[Quelle: de.wikipedia.org](https://de.wikipedia.org/wiki/Glykolyse)"))
        XCTAssertTrue(result.contains("Wie in [Abb. B3](https://de.wikipedia.org/wiki/Glykolyse) zu sehen"))
        XCTAssertTrue(result.hasSuffix("```\n[B3]\n```"), "Code-Blöcke bleiben unverändert")
    }

    private func pngData(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    func testDownloadedImagesMustBeRealAndLargeEnough() {
        XCTAssertTrue(ResearchImages.isValidImage(pngData(width: 640, height: 480)))
        XCTAssertFalse(ResearchImages.isValidImage(pngData(width: 120, height: 80)), "zu klein")
        XCTAssertFalse(ResearchImages.isValidImage(pngData(width: 1600, height: 200)), "Banner")
        XCTAssertFalse(ResearchImages.isValidImage(Data("<html>nope</html>".utf8)))
    }

    // MARK: Live (Internet)

    func testLiveWikipediaAndEuropePMCImages() async throws {
        var settings = ResearchSettings()
        settings.enabledSources = [.wikipedia, .europePMC]
        settings.rerankerMode = .off
        let pipeline = WebResearchPipeline(settings: settings, searxngURL: "", reranker: nil, exaAPIKey: "")
        let result = await pipeline.run("Glykolyse Ablauf Enzyme")
        print("Bilder:", result.images.map { "[B\($0.number)] \($0.caption.prefix(70)) — \($0.domain)" })
        print(result.modelText.suffix(600))
        guard !result.passages.isEmpty else { throw XCTSkip("Keine Belege (offline?)") }
        XCTAssertFalse(result.images.isEmpty, "Wikipedia liefert Abbildungen")
        XCTAssertLessThanOrEqual(result.images.count, ResearchImages.maxPerSearch)
        for ref in result.images {
            XCTAssertTrue(FileManager.default.fileExists(atPath: AppStorageLocation.imageFile(id: ref.imageID).path))
        }
        XCTAssertTrue(result.modelText.contains("[B1] Abbildung:"))
    }

    func testLiveEuropePMCFigures() async throws {
        let figures = await EuropePMCSource.figures(articlePage: "https://pmc.ncbi.nlm.nih.gov/articles/PMC12232762/")
        print("Abbildungen:", figures.prefix(3).map { "\($0.caption.prefix(60)) <- \($0.url)" })
        guard !figures.isEmpty else { throw XCTSkip("PMC nicht erreichbar") }
        XCTAssertTrue(figures.allSatisfy { $0.url.hasPrefix("https://") })
        let refs = await ResearchImages.downloadAll(Array(figures.prefix(2)))
        XCTAssertFalse(refs.isEmpty, "Abbildungen aus dem Fachartikel lassen sich laden")
    }
}
