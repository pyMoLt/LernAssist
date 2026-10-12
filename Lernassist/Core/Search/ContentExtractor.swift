import Foundation
import PDFKit

/// Ein extrahiertes Dokument: nur Text, keine Tags, Skripte oder Metadaten.
nonisolated struct ExtractedDocument: Equatable, Sendable {
    var title: String
    var url: String
    var published: String?
    /// Absätze/Überschriften/Listenpunkte/Tabellenzeilen in Lesereihenfolge.
    var blocks: [String]

    var text: String { blocks.joined(separator: "\n\n") }
    var characterCount: Int { blocks.reduce(0) { $0 + $1.count } }
}

/// Macht aus HTML, PDF oder Klartext reinen Lesetext.
///
/// HTML: Foundation-`XMLDocument` im Tidy-Modus (libxml2, keine Fremdbibliothek), dann
/// 1. Entfernen von Skripten, Styles, Navigation, Kopf-/Fußzeilen, Formularen, Cookie-/Werbe-Containern
/// 2. Wahl des Hauptinhalts nach Textdichte (Absatztext minus Linkanteil, Readability-Prinzip)
/// 3. Ausgabe nur der Textblöcke: Überschriften, Absätze, Listen, Zitate, Code, Tabellenzeilen
nonisolated enum ContentExtractor {

    static func extract(_ page: FetchedPage, maxPDFPages: Int = 40) throws -> ExtractedDocument {
        let mime = page.mimeType
        if mime == "application/pdf" || page.url.pathExtension.lowercased() == "pdf" {
            return extractPDF(page.data, url: page.url.absoluteString, maxPages: maxPDFPages)
        }
        if mime.hasPrefix("text/plain") || mime == "text/markdown" {
            let text = decode(page.data, encodingName: page.textEncodingName)
            return ExtractedDocument(title: "", url: page.url.absoluteString, blocks: paragraphs(of: text))
        }
        guard mime.contains("html") || mime.contains("xml") else {
            throw WebFetchError.unsupportedContent(mime)
        }
        return extractHTML(decode(page.data, encodingName: page.textEncodingName), url: page.url.absoluteString)
    }

    // MARK: HTML

    private static let removedTags = [
        "script", "style", "noscript", "svg", "canvas", "iframe", "object", "embed",
        "form", "button", "input", "select", "textarea", "video", "audio", "picture", "map",
    ]

    /// HTML5-Elemente, die libxml2s HTML4-Tidy verwirft (Inhalt bleibt, Tag verschwindet). Sie werden
    /// vorher in `<div data-la="…">` umbenannt, damit Navigation & Co. erkennbar bleiben.
    private static let html5Tags = ["nav", "header", "footer", "aside", "main", "article", "section",
                                    "figure", "figcaption", "dialog", "template", "menu", "search"]
    private static let removedHTML5 = ["nav", "header", "footer", "aside", "dialog", "template", "menu", "search"]

    private static let html5Open = try! NSRegularExpression(
        pattern: "<(" + html5Tags.joined(separator: "|") + ")(\\s[^>]*)?>",
        options: [.caseInsensitive])
    private static let html5Close = try! NSRegularExpression(
        pattern: "</(" + html5Tags.joined(separator: "|") + ")\\s*>",
        options: [.caseInsensitive])

    static func markHTML5Elements(_ html: String) -> String {
        let range = NSRange(html.startIndex..., in: html)
        let opened = html5Open.stringByReplacingMatches(in: html, range: range, withTemplate: "<div data-la=\"$1\"$2>")
        return html5Close.stringByReplacingMatches(in: opened, range: NSRange(opened.startIndex..., in: opened), withTemplate: "</div>")
    }

    private static let boilerplatePattern = try! NSRegularExpression(
        pattern: "(^|[-_ ])(cookie|consent|gdpr|banner|navbar|nav|menu|breadcrumb|footer|header|sidebar|share|sharing|social|related|recommend|comment|advert|ads|promo|newsletter|subscribe|paywall|popup|modal|toolbar|skip|toc-mobile|mw-jump|mw-editsection|noprint|reference-tools|catlinks)([-_ ]|$)",
        options: [.caseInsensitive])

    static func extractHTML(_ html: String, url: String) -> ExtractedDocument {
        guard let doc = try? XMLDocument(xmlString: markHTML5Elements(html), options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let root = doc.rootElement() else {
            return ExtractedDocument(title: "", url: url, blocks: paragraphs(of: stripTags(html)))
        }

        let title = metaContent(in: doc, property: "og:title")
            ?? (try? doc.nodes(forXPath: "//title").first?.stringValue)?.map { clean($0) }
            ?? ""
        let published = metaContent(in: doc, property: "article:published_time")
            ?? metaContent(in: doc, name: "date")
            ?? metaContent(in: doc, name: "citation_publication_date")
            ?? (try? doc.nodes(forXPath: "//time/@datetime").first?.stringValue) ?? nil

        for tag in removedTags {
            for node in (try? root.nodes(forXPath: "//*[local-name()='\(tag)']")) ?? [] { node.detach() }
        }
        for tag in removedHTML5 {
            for node in (try? root.nodes(forXPath: "//*[@data-la='\(tag)']")) ?? [] { node.detach() }
        }
        removeBoilerplateContainers(in: root)

        let container = bestContainer(in: root) ?? root
        var blocks: [String] = []
        collectBlocks(from: container, into: &blocks)
        blocks = dedupeAdjacent(blocks.filter { $0.count >= 2 })

        // Fallback: Container-Heuristik lieferte (fast) nichts → gesamter Body.
        if blocks.reduce(0, { $0 + $1.count }) < 200, container !== root {
            var all: [String] = []
            collectBlocks(from: root, into: &all)
            if all.reduce(0, { $0 + $1.count }) > blocks.reduce(0, { $0 + $1.count }) { blocks = dedupeAdjacent(all) }
        }
        return ExtractedDocument(title: String(title.prefix(300)), url: url, published: published, blocks: blocks)
    }

    private static func removeBoilerplateContainers(in root: XMLElement) {
        let candidates = (try? root.nodes(forXPath: "//*[@class or @id or @role or @aria-hidden or @hidden]")) ?? []
        for case let element as XMLElement in candidates {
            let name = element.name?.lowercased() ?? ""
            let marker5 = element.attribute(forName: "data-la")?.stringValue ?? ""
            if ["html", "body"].contains(name) || ["main", "article"].contains(marker5) { continue }
            let role = element.attribute(forName: "role")?.stringValue?.lowercased() ?? ""
            if ["navigation", "banner", "contentinfo", "complementary", "dialog", "search"].contains(role)
                || element.attribute(forName: "aria-hidden")?.stringValue == "true"
                || element.attribute(forName: "hidden") != nil {
                element.detach(); continue
            }
            let marker = [element.attribute(forName: "class")?.stringValue, element.attribute(forName: "id")?.stringValue]
                .compactMap { $0 }.joined(separator: " ")
            guard !marker.isEmpty else { continue }
            let range = NSRange(marker.startIndex..., in: marker)
            if boilerplatePattern.firstMatch(in: marker, range: range) != nil,
               // Große Inhaltsblöcke nie wegen eines Klassennamens verwerfen.
               textLength(of: element) < 2_500 {
                element.detach()
            }
        }
    }

    /// Hauptinhalt: semantische Container zuerst, sonst der Block mit der höchsten Textdichte.
    private static func bestContainer(in root: XMLElement) -> XMLElement? {
        for xpath in ["//*[@data-la='article']", "//*[@data-la='main']", "//*[@role='main']", "//*[@id='mw-content-text']", "//*[@itemprop='articleBody']"] {
            if let nodes = try? root.nodes(forXPath: xpath),
               let best = nodes.compactMap({ $0 as? XMLElement }).max(by: { textLength(of: $0) < textLength(of: $1) }),
               paragraphTextLength(of: best) >= 300 {
                return best
            }
        }
        let candidates = ((try? root.nodes(forXPath: "//*[local-name()='div' or local-name()='td']")) ?? []).compactMap { $0 as? XMLElement }
        var bestScore = 0.0
        var best: XMLElement?
        for element in candidates {
            let paragraphText = Double(paragraphTextLength(of: element))
            guard paragraphText >= 200 else { continue }
            let total = Double(max(1, textLength(of: element)))
            let linkText = Double(linkTextLength(of: element))
            let score = paragraphText * (1 - min(1, linkText / total))
            if score > bestScore { bestScore = score; best = element }
        }
        return best
    }

    private static let blockTags: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "pre", "dt", "dd", "tr", "figcaption", "caption"]

    private static func collectBlocks(from node: XMLNode, into blocks: inout [String]) {
        guard let element = node as? XMLElement else { return }
        let name = element.name?.lowercased() ?? ""
        if blockTags.contains(name) {
            let text: String
            switch name {
            case "tr":
                let cells = (element.children ?? []).compactMap { $0 as? XMLElement }
                    .filter { ["td", "th"].contains($0.name?.lowercased() ?? "") }
                    .map { clean($0.stringValue ?? "") }
                text = cells.filter { !$0.isEmpty }.joined(separator: " | ")
            case "pre":
                text = (element.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let level = Int(String(name.dropFirst())) ?? 2
                let heading = clean(element.stringValue ?? "")
                text = heading.isEmpty ? "" : String(repeating: "#", count: min(level, 4)) + " " + heading
            case "li":
                // Verschachtelte Listen nicht doppelt ausgeben: nur direkter Text + eigene Unterpunkte.
                if element.elements(forName: "ul").isEmpty && element.elements(forName: "ol").isEmpty {
                    text = "• " + clean(element.stringValue ?? "")
                } else {
                    let own = (element.children ?? []).filter { !["ul", "ol"].contains(($0 as? XMLElement)?.name?.lowercased() ?? "") }
                        .map { clean($0.stringValue ?? "") }.joined(separator: " ")
                    if !own.trimmingCharacters(in: .whitespaces).isEmpty { blocks.append("• " + clean(own)) }
                    for child in element.children ?? [] { collectBlocks(from: child, into: &blocks) }
                    return
                }
            default:
                text = clean(element.stringValue ?? "")
            }
            if !text.isEmpty && text != "•" { blocks.append(text) }
            return
        }
        // Text direkt in div/section (ohne <p>) nicht verlieren.
        let children = element.children ?? []
        let hasBlockChild = children.contains { blockTags.contains(($0 as? XMLElement)?.name?.lowercased() ?? "") || ($0 as? XMLElement).map(containsBlock) == true }
        if !hasBlockChild, ["div", "section", "article", "main", "td", "span", "body"].contains(name) {
            let text = clean(element.stringValue ?? "")
            if text.count >= 40 { blocks.append(text) }
            return
        }
        for child in children { collectBlocks(from: child, into: &blocks) }
    }

    private static func containsBlock(_ element: XMLElement) -> Bool {
        for child in element.children ?? [] {
            guard let child = child as? XMLElement else { continue }
            if blockTags.contains(child.name?.lowercased() ?? "") || containsBlock(child) { return true }
        }
        return false
    }

    private static func textLength(of element: XMLElement) -> Int {
        (element.stringValue ?? "").filter { !$0.isWhitespace }.count
    }

    private static func paragraphTextLength(of element: XMLElement) -> Int {
        ((try? element.nodes(forXPath: ".//p|.//li|.//pre|.//blockquote")) ?? [])
            .reduce(0) { $0 + ($1.stringValue ?? "").filter { !$0.isWhitespace }.count }
    }

    private static func linkTextLength(of element: XMLElement) -> Int {
        ((try? element.nodes(forXPath: ".//a")) ?? [])
            .reduce(0) { $0 + ($1.stringValue ?? "").filter { !$0.isWhitespace }.count }
    }

    private static func metaContent(in doc: XMLDocument, property: String) -> String? {
        guard let value = (try? doc.nodes(forXPath: "//meta[@property='\(property)']/@content").first?.stringValue) ?? nil else { return nil }
        let cleaned = clean(value)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func metaContent(in doc: XMLDocument, name: String) -> String? {
        guard let value = (try? doc.nodes(forXPath: "//meta[@name='\(name)']/@content").first?.stringValue) ?? nil else { return nil }
        let cleaned = clean(value)
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: PDF

    static func extractPDF(_ data: Data, url: String, maxPages: Int) -> ExtractedDocument {
        guard let pdf = PDFDocument(data: data) else { return ExtractedDocument(title: "", url: url, blocks: []) }
        var blocks: [String] = []
        for index in 0..<min(pdf.pageCount, maxPages) {
            guard let text = pdf.page(at: index)?.string else { continue }
            blocks += paragraphs(of: text)
        }
        let title = (pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String) ?? ""
        return ExtractedDocument(title: title, url: url, blocks: blocks)
    }

    // MARK: Hilfen

    static func decode(_ data: Data, encodingName: String?) -> String {
        if let encodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
            if cf != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let text = String(data: data, encoding: encoding) { return text }
            }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func paragraphs(of text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { clean($0) }
            .filter { $0.count >= 2 }
    }

    private static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "\n\n", options: .regularExpression)
    }

    private static func dedupeAdjacent(_ blocks: [String]) -> [String] {
        var result: [String] = []
        for block in blocks where result.last != block { result.append(block) }
        return result
    }

    // MARK: Bot-Seiten

    private static let botMarkers = ["please wait", "checking your browser", "enable javascript", "access denied", "captcha",
                                     "are you a robot", "bitte warten", "zugriff verweigert", "javascript aktivieren",
                                     "just a moment", "verify you are human", "cloudflare"]

    /// Bot-Sperren und Cookie-Stubs sind kein Beleg.
    static func looksLikeBotPage(_ document: ExtractedDocument) -> Bool {
        let body = document.text
        let head = (document.title + " " + body.prefix(600)).lowercased()
        return body.count < 300 || (body.count < 3_000 && botMarkers.contains { head.contains($0) })
    }
}
