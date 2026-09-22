import Foundation
import WebKit
import os

/// Service zum Abrufen und Bereinigen von Webinhalten.
class WebContentService {
    static let shared = WebContentService()

    /// Lädt den Inhalt einer Webseite und extrahiert ausschließlich bereinigte Textfelder.
    /// Versucht primär einen Headless-Browser (WKWebView), damit auch JavaScript-Seiten ihren
    /// fertigen DOM-Inhalt liefern. Fällt auf statisches HTTP zurück, falls das scheitert.
    func fetchContent(from url: URL) async throws -> String {
        try await fetchContent(from: url, offset: 0, maxCharacters: Int.max)
    }

    /// Gibt einen Abschnitt des bereinigten Gesamttexts zurück. `offset` zählt Zeichen im
    /// bereinigten Text (nicht HTML-Bytes); dadurch kann das Modell dieselbe Seite deterministisch
    /// in mehreren Tool-Aufrufen lesen.
    func fetchContent(from url: URL, offset: Int, maxCharacters: Int) async throws -> String {
        guard offset >= 0 else {
            throw NSError(domain: "WebContentService", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "Der Offset darf nicht negativ sein."])
        }
        let limit = max(1, maxCharacters)
        let fullText = try await fetchFullContent(from: url)
        guard !fullText.isEmpty else {
            throw NSError(domain: "WebContentService", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Auf der Seite wurden keine fertigen Textfelder gefunden."])
        }

        let safeOffset = min(offset, fullText.count)
        let start = fullText.index(fullText.startIndex, offsetBy: safeOffset)
        let available = fullText.count - safeOffset
        let endOffset = safeOffset + min(limit, available)
        let end = fullText.index(fullText.startIndex, offsetBy: endOffset)
        var result = String(fullText[start..<end])

        if safeOffset > 0 {
            result = "[Bereinigter Seiteninhalt ab Zeichen \(safeOffset)]\n\n" + result
        }
        if endOffset < fullText.count {
            result += "\n\n[Weitere bereinigte Inhalte verfügbar. Für den nächsten Abschnitt browse_url erneut mit offset=\(endOffset) aufrufen.]"
        } else if safeOffset >= fullText.count {
            result = "[Offset \(offset) liegt hinter dem verfügbaren Seiteninhalt von \(fullText.count) Zeichen. Es gibt keinen weiteren Text.]"
        }
        return result
    }

    private func fetchFullContent(from url: URL) async throws -> String {
        do {
            return try await fetchDynamicContent(from: url)
        } catch {
            try Task.checkCancellation()
            AppLog.tools.info("WKWebView-Fallback auf statischen Download für \(url): \(error.localizedDescription)")
            return try await fetchStaticContent(from: url)
        }
    }

    @MainActor
    private func fetchDynamicContent(from url: URL) async throws -> String {
        let scraper = WebScraper()
        let rawText = try await scraper.fetch(url: url)
        let cleaned = cleanText(rawText)
        guard !cleaned.isEmpty else {
            throw NSError(domain: "WebScraper", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Kein fertiger Text im gerenderten DOM gefunden"])
        }
        return cleaned
    }

    private func fetchStaticContent(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("LernAssist/1.0 (Macintosh; Intel Mac OS X)", forHTTPHeaderField: "User-Agent")
        // 20s statt 45s (Audit T9): Der WKWebView-Versuch davor hatte schon bis zu 30 s gedauert –
        // zusammen wären es sonst bis 75 s Worst-Case-Latenz pro Tool-Call.
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "WebContentService", code: http.statusCode,
                         userInfo: [NSLocalizedDescriptionKey: "HTTP-Fehler \(http.statusCode)"])
        }

        // Content-Type-Check (Audit T9): Ohne ihn wurden auch Bilder/Binärdateien als
        // (unbrauchbarer) Zeichensalz-"Text" ans Modell gegeben.
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let looksTextual = contentType.isEmpty
            || contentType.contains("text")
            || contentType.contains("html")
            || contentType.contains("xml")
            || contentType.contains("json")
        guard looksTextual else {
            throw NSError(domain: "WebContentService", code: -5,
                         userInfo: [NSLocalizedDescriptionKey: "Inhalt ist keine Textseite (Content-Type: \(contentType))"])
        }

        guard let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw NSError(domain: "WebContentService", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Inhalt konnte nicht als Text interpretiert werden"])
        }
        return cleanText(stripHTML(html))
    }

    /// Entfernt aktive/strukturelle HTML-Blöcke und extrahiert Text mit lesbaren Zeilenumbrüchen.
    /// Der Fallback ist absichtlich konservativ: keine Attribute, URLs, Skripte, Styles oder
    /// Metadaten wandern in den Modellkontext.
    private func stripHTML(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "(?s)<!--.*?-->", with: " ", options: .regularExpression)
        // Der komplette <head> besteht aus Metadaten/Preloads und ist kein Seiteninhalt.
        text = text.replacingOccurrences(of: "(?s)<head\\b[^>]*>.*?</head>", with: " ", options: [.regularExpression, .caseInsensitive])
        for tag in ["script", "style", "noscript", "template", "svg", "canvas", "iframe", "object", "embed", "nav", "footer", "aside", "form", "dialog"] {
            text = text.replacingOccurrences(
                of: "(?s)<\(tag)\\b[^>]*>.*?</\(tag)>",
                with: " ", options: [.regularExpression, .caseInsensitive]
            )
        }
        // Block-Tags werden vor dem Entfernen der übrigen Tags in Zeilenumbrüche umgewandelt.
        text = text.replacingOccurrences(
            of: "</?(?:h[1-6]|p|li|blockquote|pre|td|th|dt|dd|br|div|section|article|main|tr)[^>]*>",
            with: "\n", options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return decodeHTMLEntities(text)
    }

    /// Bereinigt den extrahierten Text von Metadaten-/Navigationsresten, überflüssigen Leer-
    /// räumen und doppelten Zeilen. Die Zeilen kommen aus fertigen Textfeldern, nicht aus der
    /// DOM-Gliederung.
    private func cleanText(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var cleanedLines: [String] = []
        var previous: String?
        for rawLine in lines {
            let line = rawLine
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.count >= 2, line != previous else { continue }
            cleanedLines.append(line)
            previous = line
        }
        return cleanedLines.joined(separator: "\n\n")
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        let namedEntities: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…",
            "&rsquo;": "'", "&lsquo;": "'", "&ldquo;": "„", "&rdquo;": "”",
        ]
        var decoded = text
        for (entity, replacement) in namedEntities {
            decoded = decoded.replacingOccurrences(of: entity, with: replacement)
        }

        guard let regex = try? NSRegularExpression(pattern: "&#(?:x([0-9A-Fa-f]+)|([0-9]+));") else {
            return decoded
        }
        let nsRange = NSRange(decoded.startIndex..<decoded.endIndex, in: decoded)
        let matches = regex.matches(in: decoded, range: nsRange)
        let mutable = NSMutableString(string: decoded)
        for match in matches.reversed() {
            let hex = match.range(at: 1).location == NSNotFound
                ? nil
                : (decoded as NSString).substring(with: match.range(at: 1))
            let decimal = match.range(at: 2).location == NSNotFound
                ? nil
                : (decoded as NSString).substring(with: match.range(at: 2))
            let value = UInt32(hex ?? decimal ?? "", radix: hex != nil ? 16 : 10)
            let replacement = value.flatMap(Unicode.Scalar.init).map(String.init) ?? " "
            mutable.replaceCharacters(in: match.range, with: replacement)
        }
        return mutable as String
    }
}

// MARK: - Headless WKWebView Scraper

@MainActor
private class WebScraper: NSObject, WKNavigationDelegate {
    private var webView: WKWebView!
    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self

        // Tarnung als Googlebot, um Paywalls (z.B. Bloomberg, NYT) und Bot-Blocker zu umgehen
        // (bewusstes Cloaking-Risiko in Kauf genommen, Audit T9 dokumentiert es).
        webView.customUserAgent = "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
    }

    /// Native WebKit Ad-Blocker für Cookie-Banner (verhindert das Laden von Skripten/Elementen).
    private static let blockerJSON = """
    [
        {
            "trigger": { "url-filter": ".*" },
            "action": { "type": "css-display-none", "selector": ".cookie-banner, #cookie-notice, .fc-consent-root, .cmpbox, #cmpbox, .cmpcontainer" }
        }
    ]
    """

    func fetch(url: URL) async throws -> String {
        // Kompilierung der Cookie-Blocker-Regeln ABWARTEN, bevor geladen wird (Audit T9):
        // Vorher kompilierte compileContentRuleList asynchron im init – webView.load() startete
        // sofort daneben, die Regeln wurden teils erst NACH dem Seitenaufbau installiert und
        // wirkten dann nicht mehr.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "CookieBlocker", encodedContentRuleList: Self.blockerJSON
            ) { list, _ in
                if let list = list {
                    self.webView.configuration.userContentController.add(list)
                }
                cont.resume()
            }
        }

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            webView.load(request)

            self.timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s Timeout
                if !Task.isCancelled {
                    self.resume(throwing: NSError(domain: "WebScraper", code: -2, userInfo: [NSLocalizedDescriptionKey: "WKWebView Timeout"]))
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Javascript Pipeline:
        // 1. wartet auf clientseitig gerenderten Inhalt und lädt Lazy-Content nach
        // 2. entfernt Navigation, Dialoge, Werbung, Metadaten und aktive Elemente
        // 3. wählt den semantisch größten Inhaltscontainer
        // 4. extrahiert nur fertige Textfelder statt DOM-Outline/innerHTML
        let js = """
        (async function() {
            const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
            await wait(500);

            // Cookie-/Consent-Banner zuerst ausblenden, damit sie nicht als Artikeltext gelten.
            const style = document.createElement('style');
            style.innerHTML = `
                [id*='cookie' i], [class*='cookie' i], 
                [id*='consent' i], [class*='consent' i], 
                [id*='banner' i], [class*='banner' i], 
                [id*='gdpr' i], [class*='gdpr' i], 
                [id*='overlay' i], [class*='overlay' i], 
                [id*='popup' i], [class*='popup' i],
                .fc-consent-root, .cmpbox, .cmpcontainer {
                    display: none !important;
                }
                body { overflow: auto !important; }
            `;
            document.head.appendChild(style);

            // Auto-Scroll für Lazy-Loading, mit festem Budget gegen Endlosschleifen.
            await new Promise(resolve => {
                let totalHeight = 0;
                let distance = 800;
                let timer = setInterval(() => {
                    let scrollHeight = document.body.scrollHeight;
                    window.scrollBy(0, distance);
                    totalHeight += distance;

                    if (totalHeight >= scrollHeight || totalHeight > 12000) {
                        clearInterval(timer);
                        setTimeout(resolve, 800);
                    }
                }, 100);
            });

            const removeSelectors = [
                'script', 'style', 'noscript', 'template', 'svg', 'canvas', 'iframe',
                'object', 'embed', 'nav', 'footer', 'aside', 'form', 'dialog',
                '[role="dialog"]', '[role="navigation"]', '[aria-modal="true"]',
                '[aria-hidden="true"]', '[hidden]', 'meta', 'link',
                'time', '[itemprop="datePublished"]', '[itemprop="dateModified"]',
                '[class*="byline" i]', '[class*="author" i]', '[class*="metadata" i]'
            ];
            document.querySelectorAll(removeSelectors.join(',')).forEach(el => el.remove());

            // Falls der Content nicht in article/main steckt, entferne typische Seiten- und
            // Empfehlungskästen anhand von id/class. Article/Main selbst bleiben erhalten.
            const junkMarker = /cookie|consent|gdpr|banner|popup|modal|sidebar|breadcrumb|share|social|newsletter|subscribe|advert|(^|[-_ ])ads?($|[-_ ])|related|recommend|comments?|table[-_ ]of[-_ ]contents?|(^|[-_ ])toc($|[-_ ])|pagination|pager/i;
            Array.from(document.querySelectorAll('body *')).forEach(el => {
                if (el.matches('article, main, [role="main"]')) return;
                const marker = `${el.id || ''} ${typeof el.className === 'string' ? el.className : ''}`;
                if (junkMarker.test(marker)) el.remove();
            });

            const candidates = Array.from(document.querySelectorAll('article, main, [role="main"]'));
            candidates.sort((a, b) => (b.innerText || '').length - (a.innerText || '').length);
            let root = candidates[0] || document.body;
            if ((root.innerText || '').trim().length < 300) root = document.body;

            const fields = Array.from(root.querySelectorAll(
                'h1, h2, h3, h4, h5, h6, p, li, blockquote, pre, td, th, figcaption, dt, dd'
            ));
            const lines = [];
            const seen = new Set();
            for (const field of fields) {
                if (field.closest('nav, footer, aside, form, dialog, [role="dialog"]')) continue;
                const value = (field.innerText || field.textContent || '')
                    .replace(/\\s+/g, ' ')
                    .trim();
                if (value.length < 2 || seen.has(value)) continue;
                seen.add(value);
                lines.push(value);
            }

            // Einige React-/Vue-Seiten verwenden nur div/span als Textfelder. Erst wenn keine
            // semantischen Felder existieren, fällt der Extraktor auf sichtbare Body-Zeilen zurück.
            if (lines.length === 0) {
                return (root.innerText || document.body.innerText || '')
                    .split(/\\n+/)
                    .map(value => value.replace(/\\s+/g, ' ').trim())
                    .filter(value => value.length >= 2)
                    .join('\\n');
            }
            return lines.join('\\n');
        })();
        """
        
        webView.evaluateJavaScript(js) { [weak self] result, error in
            if let text = result as? String {
                self?.resume(returning: text)
            } else {
                self?.resume(throwing: error ?? NSError(domain: "WebScraper", code: -3, userInfo: [NSLocalizedDescriptionKey: "Kein Text extrahiert"]))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resume(throwing: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        resume(throwing: error)
    }

    private func resume(returning text: String) {
        timeoutTask?.cancel()
        if let cont = continuation {
            continuation = nil
            cont.resume(returning: text)
        }
    }

    private func resume(throwing error: Error) {
        timeoutTask?.cancel()
        if let cont = continuation {
            continuation = nil
            cont.resume(throwing: error)
        }
    }
}
