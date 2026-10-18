import SwiftUI
import WebKit

// MARK: - HTMLArtifactView
// Rendert vom coding_sandbox-Tool erzeugtes HTML/JS/CSS DIREKT als Chat-Nachricht – unabhängig
// davon, ob das Modell es in seiner Textantwort erwähnt. Bewusst kein Umweg über MarkdownView/
// markdown-it (das hat `html:false` und würde das HTML nur als escapten Text zeigen).

struct HTMLArtifactView: View {
    let html: String
    /// Vom Dokument gemeldete Inhaltshöhe – das Artefakt wächst mit, statt einen festen Rahmen
    /// mit eigenem Scrollbalken zu haben.
    @State private var contentHeight: CGFloat = 360

    private static let maxInlineHeight: CGFloat = 720

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "play.rectangle")
                    .font(.caption2)
                    .foregroundStyle(DS.Ink.accent)
                Text("Interaktive Ausgabe")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NativeWindowManager.openWindow(
                        for: SandboxedHTMLWebView(html: html).frame(minWidth: 800, idealWidth: 1000, maxWidth: .infinity, minHeight: 600, idealHeight: 800, maxHeight: .infinity),
                        title: "Interaktive Ausgabe",
                        initialSize: CGSize(width: 1000, height: 800)
                    )
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .help("Vollbild / Größer anzeigen")
            }

            SandboxedHTMLWebView(html: html, contentHeight: $contentHeight, maxInlineHeight: Self.maxInlineHeight)
                .frame(height: min(max(contentHeight, 120), Self.maxInlineHeight))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
        }
    }
}

// MARK: - SandboxedHTMLWebView

extension HTMLArtifactView {
    /// Öffnet HTML aus einem Codeblock im Chat als Simulation (gleiche Sandbox wie Tool-Artefakte:
    /// CSP ohne Netzwerk, keine externen Ressourcen).
    static func openWindow(html: String) {
        NativeWindowManager.openWindow(
            for: SandboxedHTMLWebView(html: html).frame(minWidth: 640, idealWidth: 900, maxWidth: .infinity, minHeight: 480, idealHeight: 700, maxHeight: .infinity),
            title: "Simulation",
            initialSize: CGSize(width: 900, height: 700)
        )
    }

    /// Testbarer Zugang zur CSP-Härtung des Artefakt-HTML.
    static func hardenedHTML(_ html: String) -> String { SandboxedHTMLWebView.hardenedHTML(html) }
}

private struct SandboxedHTMLWebView: NSViewRepresentable {
    let html: String
    var contentHeight: Binding<CGFloat>? = nil
    var maxInlineHeight: CGFloat = .infinity

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var lastLoadedHTML: String?
        var contentHeight: Binding<CGFloat>?
        var maxInlineHeight: CGFloat = .infinity
        weak var webView: PassthroughWebView?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "artifactHeight" {
                guard let height = message.body as? Double, height > 0 else { return }
                let value = CGFloat(height)
                // Passt der Inhalt ganz hinein, gehört das Mausrad dem Chat.
                let fits = value <= maxInlineHeight + 1
                webView?.forwardsScrolling = fits
                if fits {
                    webView?.canScrollVertically = false
                    webView?.isAtTop = true
                    webView?.isAtBottom = true
                }
                if let binding = contentHeight, abs(binding.wrappedValue - value) > 1 {
                    binding.wrappedValue = value
                }
            } else if message.name == "artifactScrollState" {
                guard let dict = message.body as? [String: Any] else { return }
                if let atTop = dict["atTop"] as? Bool {
                    webView?.isAtTop = atTop
                }
                if let atBottom = dict["atBottom"] as? Bool {
                    webView?.isAtBottom = atBottom
                }
                if let canScroll = dict["canScroll"] as? Bool {
                    webView?.canScrollVertically = canScroll
                }
            }
        }

        // Audit H5: Netz-Kontrolle für modellgeneriertes HTML. Das Artefakt läuft als
        // vollwertige JS-Seite; ohne diese Entscheidungspolitik konnte es beliebige
        // Remote-Ressourcen nachladen (Skripte, Tracker, Bilder) – auch als Exfiltrations-
        // kanal für Inhalte, die eine Prompt-Injection aus Chat/Webinhalten herausgetragen
        // hat. Erlaubt bleibt nur lokal generierter Inhalt: das via loadHTMLString geladene
        // about:-Dokument, inline data:-URIs (z.B. base64-Bilder) und blob:-Objekte des
        // Skripts selbst. Sämtliche Netz-Schemes werden geblockt.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            switch url.scheme?.lowercased() {
            case "http", "https", "file", "ftp":
                decisionHandler(.cancel)
            default:
                decisionHandler(.allow)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Meldet die Dokumenthöhe sowie die vertikalen Scroll-Grenzen (beim Laden, Scrollen und jeder
    /// Größenänderung) und verhindert seitliches Überlaufen zu breiter Layouts.
    private static let sizingScript = """
    (function() {
      var style = document.createElement('style');
      style.textContent = 'html,body{overflow-x:hidden;max-width:100%;} img,canvas,svg,video,table{max-width:100%;}';
      (document.head || document.documentElement).appendChild(style);

      function updateScrollState() {
        var doc = document.documentElement;
        var body = document.body;
        var scrollY = window.pageYOffset || (doc ? doc.scrollTop : 0) || (body ? body.scrollTop : 0);
        var scrollHeight = Math.max(doc ? doc.scrollHeight : 0, body ? body.scrollHeight : 0);
        var clientHeight = window.innerHeight || (doc ? doc.clientHeight : 0) || 0;
        var canScroll = scrollHeight > clientHeight + 2;
        var atTop = !canScroll || (scrollY <= 1);
        var atBottom = !canScroll || ((scrollY + clientHeight) >= (scrollHeight - 2));
        try {
          window.webkit.messageHandlers.artifactScrollState.postMessage({
            atTop: atTop,
            atBottom: atBottom,
            canScroll: canScroll
          });
        } catch (e) {}
      }

      function report() {
        var h = Math.ceil(Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0));
        try { window.webkit.messageHandlers.artifactHeight.postMessage(h); } catch (e) {}
        updateScrollState();
      }

      window.addEventListener('scroll', updateScrollState, { passive: true });
      window.addEventListener('wheel', updateScrollState, { passive: true });
      window.addEventListener('resize', report, { passive: true });
      window.addEventListener('load', report);
      if (window.ResizeObserver) { new ResizeObserver(report).observe(document.documentElement); }
      setTimeout(report, 50);
      setTimeout(report, 300);
      setTimeout(report, 800);
    })();
    """

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        context.coordinator.contentHeight = contentHeight
        context.coordinator.maxInlineHeight = maxInlineHeight
        if contentHeight != nil {
            config.userContentController.addUserScript(WKUserScript(source: Self.sizingScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            config.userContentController.add(context.coordinator, name: "artifactHeight")
            config.userContentController.add(context.coordinator, name: "artifactScrollState")
        }
        // Inline-JavaScript ausdrücklich aktivieren. Auf einzelnen macOS-/WebKit-Ständen
        // war die implizite Standardeinstellung uneinheitlich; dann erschien das Artefakt
        // wie ein statisches Bild, obwohl es JavaScript enthielt.
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Kein persistenter Datenspeicher – jede Ausgabe startet mit leerem Cache/Cookies.
        config.websiteDataStore = .nonPersistent()
        let webView = PassthroughWebView(frame: .zero, configuration: config)
        webView.forwardsScrolling = contentHeight != nil
        context.coordinator.webView = webView
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        webView.navigationDelegate = context.coordinator
        let hardenedHTML = Self.hardenedHTML(html)
        webView.loadHTMLString(hardenedHTML, baseURL: nil)
        context.coordinator.lastLoadedHTML = hardenedHTML
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.contentHeight = contentHeight
        // Reload-Guard (Audit C8): Während das Artefakt streamt, feuert der 200-ms-Flush
        // SwiftUI-Updates – ein bedingungsloses loadHTMLString lud die Seite bei JEDEM Update
        // komplett neu: Flackern, Verlust von Scroll-Position/JS-State, massive CPU-Last.
        // Nur neu laden, wenn sich der HTML-Inhalt tatsächlich geändert hat.
        let hardenedHTML = Self.hardenedHTML(html)
        guard context.coordinator.lastLoadedHTML != hardenedHTML else { return }
        context.coordinator.lastLoadedHTML = hardenedHTML
        nsView.loadHTMLString(hardenedHTML, baseURL: nil)
    }

    /// Inline HTML/JS darf interaktiv bleiben, erhält aber keinen Netzwerkzugriff. CSP ergänzt
    /// die Navigation-Policy: Sie blockiert auch `fetch`, XHR und externe Subressourcen, die nicht
    /// als NavigationAction beim Delegate auftauchen. `data:`/`blob:` bleiben für lokale Plots
    /// und vom Skript erzeugte Artefakte verfügbar.
    static func hardenedHTML(_ html: String) -> String {
        let csp = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data: blob:; connect-src 'none'; media-src data: blob:; worker-src blob:;\">"
        // Eine CSP per <meta> wirkt NUR im <head>. Früher traf die Suche nach "<head" auch
        // "<header>" – fehlte ein echtes <head>, landete die Policy im Body und wurde ignoriert
        // (Audit 2026-10-12, H-1). Deshalb exakt auf das head-Tag matchen und sonst einen
        // eigenen head erzeugen.
        if let head = html.range(of: #"<head(\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) {
            var result = html
            result.insert(contentsOf: csp, at: head.upperBound)
            return result
        }
        if let root = html.range(of: #"<html(\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) {
            var result = html
            result.insert(contentsOf: "<head>" + csp + "</head>", at: root.upperBound)
            return result
        }
        // Ein <head> ganz am Dokumentanfang wird vom HTML-Parser als Kopf übernommen.
        let doctype = html.range(of: #"^\s*<!doctype[^>]*>"#, options: [.regularExpression, .caseInsensitive])
        var result = html
        result.insert(contentsOf: "<head>" + csp + "</head>", at: doctype?.upperBound ?? result.startIndex)
        return result
    }
}

/// WKWebView mit Scroll-Verkettung (Scroll Chaining): Passt das Dokument vollständig hinein,
/// oder ist der innere Bereich in Scrollrichtung am oberen/unteren Rand angekommen, wird das
/// Mausrad nahtlos an den umgebenden Chat übergeben, statt im Widget „hängen zu bleiben“.
final class PassthroughWebView: WKWebView {
    var forwardsScrolling = false
    var isAtTop = true
    var isAtBottom = true
    var canScrollVertically = false

    override func scrollWheel(with event: NSEvent) {
        // Horizontale Gesten (z. B. Slider, horizontale Tabellen/Plots) im Webview belassen
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
            return
        }

        // Passt der Inhalt ganz hinein oder kann er nicht vertikal scrollen, gehört das Rad sofort dem Chat
        if forwardsScrolling || !canScrollVertically {
            forwardToChat(event)
            return
        }

        let deltaY = event.scrollingDeltaY
        // deltaY > 0 = nach oben scrollen; deltaY < 0 = nach unten scrollen
        let cannotScrollFurther = (deltaY > 0 && isAtTop) || (deltaY < 0 && isAtBottom)

        if cannotScrollFurther {
            forwardToChat(event)
            return
        }

        super.scrollWheel(with: event)
    }

    private func forwardToChat(_ event: NSEvent) {
        if let outer = enclosingScrollView {
            outer.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }
}
