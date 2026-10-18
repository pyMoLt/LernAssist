import AppKit
import WebKit
import UniformTypeIdentifiers

/// Exportiert eine Antwort (z. B. einen Lernzettel aus `/summary`) als PDF oder Markdown.
/// Das PDF nutzt denselben Renderer wie der Chat (Markdown, Formeln, Mermaid), immer hell und
/// auf A4-Seiten umbrochen.
@MainActor
final class StudySheetExporter: NSObject, WKNavigationDelegate {
    static let shared = StudySheetExporter()

    private var window: NSWindow?
    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Never>?

    // MARK: Markdown

    func exportMarkdown(_ markdown: String, suggestedName: String) {
        guard let url = savePanel(name: suggestedName, type: UTType(filenameExtension: "md") ?? .plainText) else { return }
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: PDF

    func exportPDF(_ markdown: String, suggestedName: String) {
        guard let url = savePanel(name: suggestedName, type: .pdf) else { return }
        Task {
            if await renderPDF(markdown, to: url) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    /// Rendert Markdown wie im Chat und schreibt es als A4-PDF. Gibt zurück, ob die Datei Inhalt hat.
    func renderPDF(_ markdown: String, to url: URL) async -> Bool {
        guard webView == nil, let (htmlURL, dirURL) = MarkdownWebView.bundleURLs() else { return false }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 1000), configuration: WKWebViewConfiguration())
        webView.navigationDelegate = self
        // Druckausgabe immer hell, unabhängig vom Erscheinungsbild der App.
        webView.appearance = NSAppearance(named: .aqua)
        // WKWebView druckt nur zuverlässig, wenn er in einem (unsichtbaren) Fenster hängt.
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 700, height: 1000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = webView
        window.orderBack(nil)
        self.window = window
        self.webView = webView
        defer {
            self.window?.orderOut(nil)
            self.window = nil
            self.webView = nil
        }

        await withCheckedContinuation { continuation in
            loadContinuation = continuation
            webView.loadFileURL(htmlURL, allowingReadAccessTo: dirURL)
        }
        guard let data = try? JSONEncoder().encode(markdown), let js = String(data: data, encoding: .utf8) else { return false }
        _ = try? await webView.evaluateJavaScript("updateContent(\(js), 1.0);")
        // Mermaid/KaTeX zeichnen asynchron (Mermaid nach 450 ms Ruhe) – kurz warten.
        try? await Task.sleep(nanoseconds: 1_800_000_000)

        // Kein NSPrintOperation: Mit einem Offscreen-WKWebView rendert der Druckweg endlos Seiten
        // und friert die App ein. Stattdessen Ausschnitte per createPDF, umgebrochen an
        // Absatzgrenzen, mit Rand auf A4 gesetzt.
        try? FileManager.default.removeItem(at: url)
        let pageWidth = Self.a4.width - 2 * Self.margin.width
        let pageHeight = Self.a4.height - 2 * Self.margin.height
        webView.setFrameSize(NSSize(width: pageWidth, height: pageHeight))
        try? await Task.sleep(nanoseconds: 300_000_000) // Layout nach der Breitenänderung
        let breaks = await pageBreaks(in: webView, pageHeight: pageHeight)
        var pages: [(Data, CGFloat)] = []
        var top: CGFloat = 0
        for bottom in breaks {
            let config = WKPDFConfiguration()
            config.rect = CGRect(x: 0, y: top, width: pageWidth, height: max(1, bottom - top))
            if let data = try? await webView.pdf(configuration: config) { pages.append((data, bottom - top)) }
            top = bottom
        }
        if let pdf = Self.composeA4(pages) { try? pdf.write(to: url, options: .atomic) }

        if !Self.hasContent(url), let pdfData = await Self.generatePDFData(from: webView) {
            // Notfall: eine lange Seite statt A4-Umbruch.
            try? pdfData.write(to: url, options: .atomic)
        }
        return Self.hasContent(url)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.loadContinuation?.resume()
            self.loadContinuation = nil
        }
    }

    // MARK: Seitenumbruch

    static let a4 = CGSize(width: 595, height: 842)
    static let margin = CGSize(width: 40, height: 36)

    /// Seitenenden (y in Punkten) an Grenzen von Absätzen, Listenpunkten, Tabellenzeilen usw.
    /// Ein Element, das höher als eine Seite ist, wird notgedrungen geteilt.
    private func pageBreaks(in webView: WKWebView, pageHeight: CGFloat) async -> [CGFloat] {
        let js = """
        (function() {
          var root = document.getElementById('content') || document.body;
          var ends = [];
          root.querySelectorAll('p, li, h1, h2, h3, h4, pre, table tr, blockquote, .mermaid-block, .katex-display, img, hr').forEach(function(el) {
            var r = el.getBoundingClientRect();
            ends.push(r.bottom + window.scrollY);
          });
          return JSON.stringify({ ends: ends, height: Math.ceil(document.documentElement.scrollHeight) });
        })();
        """
        guard let raw = try? await webView.evaluateJavaScript(js) as? String,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let total = (object["height"] as? NSNumber)?.doubleValue else { return [pageHeight] }
        let ends = ((object["ends"] as? [NSNumber]) ?? []).map { CGFloat($0.doubleValue) }.sorted()
        return Self.pageBreaks(elementEnds: ends, totalHeight: CGFloat(total), pageHeight: pageHeight)
    }

    /// Reine Umbruch-Logik (testbar): größtes Elementende, das noch auf die Seite passt.
    nonisolated static func pageBreaks(elementEnds: [CGFloat], totalHeight: CGFloat, pageHeight: CGFloat) -> [CGFloat] {
        guard totalHeight > 0, pageHeight > 0 else { return [] }
        var breaks: [CGFloat] = []
        var top: CGFloat = 0
        while top < totalHeight - 1 {
            let limit = top + pageHeight
            if limit >= totalHeight { breaks.append(totalHeight); break }
            let candidate = elementEnds.last { $0 > top + pageHeight * 0.3 && $0 <= limit }
            let bottom = candidate ?? limit
            breaks.append(bottom)
            top = bottom
        }
        return breaks
    }

    /// Setzt die Seiten-Ausschnitte mit Rand auf A4-Seiten.
    static func composeA4(_ pages: [(Data, CGFloat)]) -> Data? {
        guard !pages.isEmpty else { return nil }
        let output = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: a4)
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        for (data, _) in pages {
            guard let provider = CGDataProvider(data: data as CFData),
                  let document = CGPDFDocument(provider), let page = document.page(at: 1) else { continue }
            let box = page.getBoxRect(.mediaBox)
            context.beginPDFPage(nil)
            // Oben bündig unter dem Rand platzieren (PDF-Koordinaten: Ursprung unten links).
            context.translateBy(x: margin.width, y: a4.height - margin.height - box.height)
            context.drawPDFPage(page)
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }

    // MARK: Hilfen

    private func savePanel(name: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = Self.fileName(from: name) + "." + (type.preferredFilenameExtension ?? "txt")
        panel.canCreateDirectories = true
        panel.level = .floating
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Dateiname aus Titel oder erster Überschrift.
    nonisolated static func fileName(from text: String) -> String {
        let firstLine = text.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "Lernzettel"
        let cleaned = firstLine.replacingOccurrences(of: "#", with: "")
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Lernzettel" : String(cleaned.prefix(60))
    }

    /// Wurde eine PDF-Datei mit Inhalt geschrieben?
    static func hasContent(_ url: URL) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0) > 1_000
    }

    /// Erzeugt PDF-Rohdaten direkt über WKWebView.createPDF als robuster Fallback.
    static func generatePDFData(from webView: WKWebView) async -> Data? {
        await withCheckedContinuation { continuation in
            webView.createPDF(configuration: WKPDFConfiguration()) { result in
                switch result {
                case .success(let data):
                    continuation.resume(returning: data)
                case .failure:
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
