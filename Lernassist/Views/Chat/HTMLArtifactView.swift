import SwiftUI
import WebKit

// MARK: - HTMLArtifactView
// Rendert vom coding_sandbox-Tool erzeugtes HTML/JS/CSS DIREKT als Chat-Nachricht – unabhängig
// davon, ob das Modell es in seiner Textantwort erwähnt. Bewusst kein Umweg über MarkdownView/
// markdown-it (das hat `html:false` und würde das HTML nur als escapten Text zeigen).

struct HTMLArtifactView: View {
    let html: String


    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.slash.chevron.right")
                    .font(.caption2)
                    .foregroundColor(.purple)
                Text("Interaktive Ausgabe")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
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

            // Größere Initialhöhe, damit Diagramme/UIs nicht gedrungen wirken
            ResizableContainer(initialHeight: 500, minHeight: 250) {
                SandboxedHTMLWebView(html: html)
            }
        }
    }
}

// MARK: - SandboxedHTMLWebView

private struct SandboxedHTMLWebView: NSViewRepresentable {
    let html: String

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastLoadedHTML: String?

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

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Inline-JavaScript ausdrücklich aktivieren. Auf einzelnen macOS-/WebKit-Ständen
        // war die implizite Standardeinstellung uneinheitlich; dann erschien das Artefakt
        // wie ein statisches Bild, obwohl es JavaScript enthielt.
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Kein persistenter Datenspeicher – jede Ausgabe startet mit leerem Cache/Cookies.
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        webView.navigationDelegate = context.coordinator
        let hardenedHTML = Self.hardenedHTML(html)
        webView.loadHTMLString(hardenedHTML, baseURL: nil)
        context.coordinator.lastLoadedHTML = hardenedHTML
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
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
    private static func hardenedHTML(_ html: String) -> String {
        let csp = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data: blob:; connect-src 'none'; media-src data: blob:; worker-src blob:;\">"
        if let headRange = html.range(of: "<head", options: .caseInsensitive),
           let end = html.range(of: ">", range: headRange.lowerBound..<html.endIndex) {
            var result = html
            result.insert(contentsOf: csp, at: end.upperBound)
            return result
        }
        return csp + html
    }
}
