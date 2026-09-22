import SwiftUI
import WebKit

// MARK: - MarkdownView (SwiftUI-Wrapper)

struct MarkdownView: View {
    let markdown: String
    var fontScale: Double = 1.0
    var onExplainSelection: ((String) -> Void)? = nil

    @State private var webViewHeight: CGFloat = 30

    var body: some View {
        MarkdownWebView(markdown: markdown, fontScale: fontScale, dynamicHeight: $webViewHeight, onExplainSelection: onExplainSelection)
            .frame(height: max(webViewHeight, 30))
    }
}

// MARK: - NonScrollingWebView
// WKWebView-Unterklasse, die Scroll-Events an den übergeordneten Responder
// (= SwiftUI ScrollView) weiterleitet, statt sie selbst zu schlucken.

private class NonScrollingWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        // Nicht selbst verarbeiten → an nächsten Responder (SwiftUI ScrollView) weiterleiten
        nextResponder?.scrollWheel(with: event)
    }
}

// MARK: - MarkdownWebView (NSViewRepresentable)

struct MarkdownWebView: NSViewRepresentable {
    let markdown: String
    var fontScale: Double = 1.0
    @Binding var dynamicHeight: CGFloat
    var onExplainSelection: ((String) -> Void)?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        
        config.userContentController.add(context.coordinator, name: "heightChanged")
        config.userContentController.add(context.coordinator, name: "linkClicked")
        config.userContentController.add(context.coordinator, name: "explainSelection")

        let hideScrollbarCSS = """
            ::-webkit-scrollbar { display: none !important; }
            html, body { overflow: hidden !important; }
            """
        let hideScrollbarScript = WKUserScript(
            source: """
                (function() {
                    var s = document.createElement('style');
                    s.textContent = \\(Self.jsStringLiteral(hideScrollbarCSS));
                    document.documentElement.appendChild(s);
                })();
                """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(hideScrollbarScript)

        let webView = NonScrollingWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        
        webView.navigationDelegate = context.coordinator

        context.coordinator.webView = webView
        context.coordinator.pendingMarkdown = markdown

        if let (htmlURL, resourcesURL) = Self.bundleURLs() {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: resourcesURL)
        } else {
            webView.loadHTMLString(Self.minimalFallbackHTML, baseURL: nil)
        }
        return webView
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        // No manual enqueue needed
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Parent-Struktur aktuell halten (Audit C9): Der Coordinator wurde nur EINMAL beim
        // makeCoordinator() mit der Parent-Kopie initialisiert – die Binding- und Callback-
        // Referenzen im JS-Message-Handler waren eingefrorene Kopien vom ersten Konstruktions-
        // zeitpunkt. Funktioniert heute zufällig (Binding-Identität), bricht bei jedem Refactor.
        context.coordinator.parent = self
        context.coordinator.fontScale = fontScale
        context.coordinator.updateContent(markdown)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - Hilfsfunktionen

    /// Wandelt einen Swift-String in ein sicheres JS-String-Literal um (mit JSON-Encoding).
    static func jsStringLiteral(_ s: String) -> String {
        (try? String(data: JSONEncoder().encode(s), encoding: .utf8)) ?? "\"\""
    }

    // MARK: - Bundle-Pfade ermitteln

    /// Gibt (index.html URL, Resources/-Verzeichnis URL) zurück.
    /// Versucht zuerst den Pfad mit Resources/-Unterordner,
    /// dann direkt im Bundle-Resources (falls Xcode die Struktur flach kopiert).
    static func bundleURLs() -> (html: URL, dir: URL)? {
        let fm = FileManager.default
        guard let bundleRes = Bundle.main.resourceURL else { return nil }

        // Variante 1: Lernassist/Resources/ → MyApp.app/Contents/Resources/Resources/
        let subDir  = bundleRes.appendingPathComponent("Resources")
        let subHTML = subDir.appendingPathComponent("index.html")
        if fm.fileExists(atPath: subHTML.path) {
            return (subHTML, subDir)
        }

        // Variante 2: Dateien direkt in Resources/ (Xcode hat Ordner-Struktur geflacht)
        let flatHTML = bundleRes.appendingPathComponent("index.html")
        if fm.fileExists(atPath: flatHTML.path) {
            return (flatHTML, bundleRes)
        }

        return nil
    }

    // MARK: - Minimaler Fallback (plain text, kein Markdown)

    static let minimalFallbackHTML = """
    <!DOCTYPE html>
    <html>
    <head><meta charset="UTF-8">
    <style>
    body { margin:0; padding:0; background:transparent;
           font-family:-apple-system,sans-serif; font-size:14px;
           line-height:1.6; word-wrap:break-word; }
    @media(prefers-color-scheme:dark){body{color:#e0e0e0;}}
    code,pre{font-family:'SF Mono',Menlo,monospace;font-size:.88em;
             background:rgba(0,0,0,.08);border-radius:4px;padding:2px 5px;}
    pre{display:block;padding:10px;overflow-x:auto;}pre code{background:none;padding:0;}
    </style>
    </head>
    <body><div id="content"></div>
    <script>
    function updateContent(t){
      document.getElementById('content').textContent=t;
      requestAnimationFrame(function(){
        try{window.webkit.messageHandlers.heightChanged.postMessage(
          document.body.scrollHeight);}catch(e){}
      });
    }
    </script></body></html>
    """

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MarkdownWebView
        var isPageLoaded = false
        var pendingMarkdown: String?
        var lastInjectedMarkdown: String?   // Duplikat-Schutz: kein JS wenn Inhalt unverändert
        var lastInjectedFontScale: Double   // ... und kein JS, wenn auch die Skala unverändert ist
        var fontScale: Double
        weak var webView: WKWebView?

        init(_ parent: MarkdownWebView) {
            self.parent = parent
            self.fontScale = parent.fontScale
            self.lastInjectedFontScale = parent.fontScale
        }

        // Seite fertig → ausstehenden Inhalt injizieren
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isPageLoaded = true
            if let md = pendingMarkdown {
                inject(md, into: webView)
                pendingMarkdown = nil
            }
        }

        // SwiftUI hat neuen Markdown-Inhalt (oder eine neue Schriftgröße)
        func updateContent(_ markdown: String) {
            // Kein erneutes Rendern wenn Inhalt UND Schriftgröße identisch (z.B. SwiftUI
            // rerender anderer Messages). Wichtig (Audit C10): Eine reine fontScale-Änderung
            // muss die Injektion ebenfalls auslösen – vorher brach der markdown-Guard ab,
            // BEVOR die neue Schriftgröße ins JS gesetzt wurde, und die gerenderten
            // Nachrichten blieben auf der alten Größe, bis der nächste Inhalt kam.
            let contentChanged = markdown != lastInjectedMarkdown
            let scaleChanged = fontScale != lastInjectedFontScale
            guard contentChanged || scaleChanged else { return }
            guard let wv = webView else { pendingMarkdown = markdown; return }
            if isPageLoaded {
                inject(markdown, into: wv)
            } else {
                pendingMarkdown = markdown
            }
        }

        // Sicheres JS-Encoding via JSONEncoder (kein manuelles Escaping nötig)
        // Rate-limiting während Streaming: max alle 150ms injizieren (Performance!)
        private var lastInjectTime: Date = .distantPast
        private var injectTimer: Timer?

        private func inject(_ markdown: String, into webView: WKWebView) {
            // Falls gerade gestreamt wird, drosseln wir die Updates
            let now = Date()
            let streaming = markdown.count > (lastInjectedMarkdown?.count ?? 0) + 1 // Heuristik für Streaming

            if streaming && now.timeIntervalSince(lastInjectTime) < 0.15 {
                // Zu schnell → Timer setzen für das finale Update des Chunks
                injectTimer?.invalidate()
                injectTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                    guard let self, let wv = self.webView else { return }
                    self.performInject(markdown, into: wv)
                }
                return
            }

            performInject(markdown, into: webView)
        }

        private func performInject(_ markdown: String, into webView: WKWebView) {
            guard
                let data   = try? JSONEncoder().encode(markdown),
                let jsStr  = String(data: data, encoding: .utf8)
            else { return }
            
            lastInjectTime = Date()
            injectTimer?.invalidate()
            injectTimer = nil

            lastInjectedMarkdown = markdown
            lastInjectedFontScale = fontScale
            webView.evaluateJavaScript("updateContent(\(jsStr), \(fontScale));", completionHandler: nil)
        }

        // Höhe und Link-Klicks vom JS empfangen
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case "heightChanged":
                if let raw = message.body as? Double {
                    let h = CGFloat(raw) + 8
                    DispatchQueue.main.async {
                        // Höhendifferenz von mindestens 5px nötig, um Layout-Update zu triggern
                        // Verhindert Mikrozittern bei einfließendem Text
                        if abs(h - self.parent.dynamicHeight) > 5 {
                            self.parent.dynamicHeight = h
                        }
                    }
                }
            case "linkClicked":
                if let urlStr = message.body as? String, let url = URL(string: urlStr) {
                    NSWorkspace.shared.open(url)
                }
            case "explainSelection":
                if let dict = message.body as? [String: Any], let text = dict["text"] as? String {
                    DispatchQueue.main.async {
                        self.parent.onExplainSelection?(text)
                    }
                }
            default: break
            }
        }
    }
}
