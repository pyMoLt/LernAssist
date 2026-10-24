import SwiftUI
import WebKit

// MARK: - HTMLArtifactView
// Rendert vom coding_sandbox-Tool erzeugtes HTML/JS/CSS DIREKT als Chat-Nachricht – unabhängig
// davon, ob das Modell es in seiner Textantwort erwähnt. Bewusst kein Umweg über MarkdownView/
// markdown-it (das hat `html:false` und würde das HTML nur als escapten Text zeigen).

struct HTMLArtifactView: View {
    let html: String
    /// Vom Nutzer freigegebene Domains externer Bibliotheken.
    var allowedHosts: [String] = []
    var isCollapsed: Bool = false
    var onToggleCollapse: (() -> Void)? = nil
    /// Datei der Ausgabe im Chat-Ordner (Browser/Finder); nil = noch keine.
    var fileURL: (() -> URL?)? = nil

    /// Vom Dokument gemeldete Inhaltshöhe – das Artefakt wächst mit, statt einen festen Rahmen
    /// mit eigenem Scrollbalken zu haben.
    /// Schlüssel für den Höhen-Speicher (Lazy-Chatliste, siehe RenderedHeightCache).
    var heightKey: String? = nil
    @State private var contentHeight: CGFloat = 360
    @State private var reloadToken = 0
    @State private var isHeaderHovered = false
    /// Breite der Ausgabe im Chat – das Zusatzfenster öffnet in derselben Breite.
    @State private var inlineWidth: CGFloat = 720

    private static let maxInlineHeight: CGFloat = 720

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if !isCollapsed {
                SandboxedHTMLWebView(html: html, allowedHosts: allowedHosts, contentHeight: $contentHeight,
                                     maxInlineHeight: Self.maxInlineHeight, reloadToken: reloadToken,
                                     onDoubleClick: { openSizedWindow() })
                    .frame(height: min(max(contentHeight, 120), Self.maxInlineHeight))
                    .onAppear {
                        if let heightKey, let cached = RenderedHeightCache.shared.height(for: heightKey) { contentHeight = cached }
                    }
                    .onChange(of: contentHeight) { _, height in
                        if let heightKey { RenderedHeightCache.shared.store(height, for: heightKey) }
                    }
                    .background(GeometryReader { proxy in
                        Color.clear.onAppear { inlineWidth = proxy.size.width }
                            .onChange(of: proxy.size.width) { _, width in inlineWidth = width }
                    })
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
                    .transition(.opacity)

            }
        }
    }

    // MARK: Kopfzeile: Klick = ein-/ausklappen, Doppelklick = Vollbild

    private var header: some View {
        HStack(spacing: 6) {
            titleArea
            Menu {
                Button(L("Im Vollbild öffnen")) { openFullScreen() }
                Button(L("In eigenem Fenster öffnen")) { openSizedWindow() }
                Divider()
                Button(L("Im Browser öffnen")) { if let url = fileURL?() { NSWorkspace.shared.open(url) } }
                    .disabled(fileURL == nil)
                Button(L("Im Finder zeigen")) { if let url = fileURL?() { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                    .disabled(fileURL == nil)
                Divider()
                Button(L("Neu laden")) { reloadToken += 1 }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("Weitere Aktionen"))
            .accessibilityLabel(L("Weitere Aktionen"))
            Button { openFullScreen() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .help(L("Im Vollbild öffnen (oder Doppelklick auf die Kopfzeile)"))
            .accessibilityLabel(L("Im Vollbild öffnen"))
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .fill(isHeaderHovered ? DS.Surface.chipHover : .clear)
        )
        .onHover { isHeaderHovered = $0 }
    }

    /// Klickfläche der Kopfzeile: Klick = ein-/ausklappen, Doppelklick = Vollbild.
    private var titleArea: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
            Image(systemName: "play.rectangle")
                .font(.caption2)
                .foregroundStyle(DS.Ink.accent)
            Text(L("Interaktive Ausgabe"))
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
        // Klick und Doppelklick über AppKit: zuverlässig auch im nicht aktiven Panel.
        .overlay(ClickCatcher(onSingleClick: { toggleCollapse() }, onDoubleClick: { openSizedWindow() }))
        .help(isCollapsed ? L("Klicken zum Aufklappen · Doppelklick: eigenes Fenster") : L("Klicken zum Einklappen · Doppelklick: eigenes Fenster"))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(isCollapsed ? L("Interaktive Ausgabe aufklappen") : L("Interaktive Ausgabe einklappen"))
        .accessibilityAction { toggleCollapse() }
        .accessibilityAction(named: L("Im Vollbild öffnen")) { openFullScreen() }
        .accessibilityAction(named: L("In eigenem Fenster öffnen")) { openSizedWindow() }
    }

    private func toggleCollapse() {
        withAnimation(.easeInOut(duration: 0.18)) { onToggleCollapse?() }
    }

    private func openFullScreen() {
        Self.openWindow(html: html, allowedHosts: allowedHosts, fullScreen: true,
                        contentSize: CGSize(width: inlineWidth, height: contentHeight))
    }

    /// Eigenes Fenster in der Größe der Ausgabe (Breite wie im Chat, volle Höhe).
    private func openSizedWindow() {
        Self.openWindow(html: html, allowedHosts: allowedHosts,
                        contentSize: CGSize(width: inlineWidth, height: contentHeight))
    }
}

// MARK: - SandboxedHTMLWebView

extension HTMLArtifactView {
    /// Öffnet eine Ausgabe in einem eigenen Fenster (gleiche Sandbox: CSP ohne Netzwerk,
    /// lokale Bibliotheken, nur freigegebene Domains). Auch für HTML aus Codeblöcken im Chat.
    /// `contentSize`: Größe der Ausgabe im Chat. Das Fenster öffnet in dieser Größe (höchstens 90 % des
    /// Bildschirms); wird es schmaler, verkleinert sich die Seite proportional (Seiten-Zoom).
    static func openWindow(html: String, allowedHosts: [String]? = nil, fullScreen: Bool = false,
                           title: String = L("Interaktive Ausgabe"), contentSize: CGSize? = nil) {
        var hosts = allowedHosts ?? []
        if allowedHosts == nil {
            // HTML aus einem Codeblock: unbekannte Domains jetzt freigeben lassen.
            let unknown = HTMLLibraries.rewrite(html).unknownHosts
            if !unknown.isEmpty { hosts = HTMLLibraryPermissions.shared.requestPermission(hosts: unknown) ?? [] }
        }
        let design = contentSize ?? CGSize(width: 1000, height: 760)
        let size = ContentWindowSize.fitting(content: design)
        NativeWindowManager.openWindow(
            for: SandboxedHTMLWebView(html: html, allowedHosts: hosts, designWidth: design.width)
                .frame(minWidth: 320, maxWidth: .infinity, minHeight: 240, maxHeight: .infinity),
            title: title,
            initialSize: size,
            fullScreen: fullScreen
        )
    }

    /// Testbarer Zugang zur CSP-Härtung des Artefakt-HTML.
    static func hardenedHTML(_ html: String) -> String { HTMLArtifactRuntime.hardened(html) }
}

private struct SandboxedHTMLWebView: NSViewRepresentable {
    let html: String
    var allowedHosts: [String] = []
    var contentHeight: Binding<CGFloat>? = nil
    var maxInlineHeight: CGFloat = .infinity
    var reloadToken: Int = 0
    var onDoubleClick: (() -> Void)? = nil
    /// Nur im Zusatzfenster: Breite, für die die Ausgabe gebaut wurde. Ist das Fenster schmaler,
    /// wird die Seite proportional verkleinert statt umzubrechen.
    var designWidth: CGFloat? = nil
    var onError: ((String) -> Void)? = nil

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var lastLoadedHTML: String?
        var lastReloadToken = 0
        var onError: ((String) -> Void)?
        var contentHeight: Binding<CGFloat>?
        var maxInlineHeight: CGFloat = .infinity
        weak var webView: PassthroughWebView?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == HTMLArtifactRuntime.errorHandlerName {
                if let text = message.body as? String { onError?(text) }
            } else if message.name == "artifactHeight" {
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
        context.coordinator.onError = onError
        context.coordinator.lastReloadToken = reloadToken
        let handler = WeakMessageHandler(context.coordinator)
        if contentHeight != nil {
            config.userContentController.addUserScript(WKUserScript(source: Self.sizingScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            config.userContentController.add(handler, name: "artifactHeight")
            config.userContentController.add(handler, name: "artifactScrollState")
        }
        // Fehlerbrücke: Skriptfehler sichtbar machen statt einer stillen, toten Seite.
        config.userContentController.addUserScript(WKUserScript(source: HTMLArtifactRuntime.errorBridgeScript,
                                                                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.add(handler, name: HTMLArtifactRuntime.errorHandlerName)
        // Lokale Bibliotheken (Chart.js, D3, three.js …) aus dem App-Bundle.
        config.setURLSchemeHandler(LibrarySchemeHandler(), forURLScheme: HTMLLibraries.scheme)
        // Inline-JavaScript ausdrücklich aktivieren. Auf einzelnen macOS-/WebKit-Ständen
        // war die implizite Standardeinstellung uneinheitlich; dann erschien das Artefakt
        // wie ein statisches Bild, obwohl es JavaScript enthielt.
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Kein persistenter Datenspeicher – jede Ausgabe startet mit leerem Cache/Cookies.
        config.websiteDataStore = .nonPersistent()
        let webView = PassthroughWebView(frame: .zero, configuration: config)
        webView.forwardsScrolling = contentHeight != nil
        webView.onDoubleClick = onDoubleClick
        webView.designWidth = designWidth
        context.coordinator.webView = webView
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        webView.navigationDelegate = context.coordinator
        let rendered = HTMLArtifactRuntime.renderable(html, allowedHosts: allowedHosts)
        webView.loadHTMLString(rendered, baseURL: HTMLLibraries.baseURL)
        context.coordinator.lastLoadedHTML = rendered
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if let pt = nsView as? PassthroughWebView {
            pt.onDoubleClick = onDoubleClick
            pt.designWidth = designWidth
        }
        context.coordinator.contentHeight = contentHeight
        context.coordinator.onError = onError
        if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            context.coordinator.lastLoadedHTML = nil
        }
        // Reload-Guard (Audit C8): Während das Artefakt streamt, feuert der 200-ms-Flush
        // SwiftUI-Updates – ein bedingungsloses loadHTMLString lud die Seite bei JEDEM Update
        // komplett neu: Flackern, Verlust von Scroll-Position/JS-State, massive CPU-Last.
        // Nur neu laden, wenn sich der HTML-Inhalt tatsächlich geändert hat.
        let rendered = HTMLArtifactRuntime.renderable(html, allowedHosts: allowedHosts)
        guard context.coordinator.lastLoadedHTML != rendered else { return }
        context.coordinator.lastLoadedHTML = rendered
        nsView.loadHTMLString(rendered, baseURL: HTMLLibraries.baseURL)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        let controller = nsView.configuration.userContentController
        ["artifactHeight", "artifactScrollState", HTMLArtifactRuntime.errorHandlerName].forEach {
            controller.removeScriptMessageHandler(forName: $0)
        }
    }

}

/// WKWebView mit Scroll-Verkettung (Scroll Chaining): Passt das Dokument vollständig hinein,
/// oder ist der innere Bereich in Scrollrichtung am oberen/unteren Rand angekommen, wird das
/// Mausrad nahtlos an den umgebenden Chat übergeben, statt im Widget „hängen zu bleiben“.
final class PassthroughWebView: WKWebView {
    /// Der erste Klick zählt sofort – auch wenn das schwebende Panel gerade nicht aktiv ist
    /// (sonst aktivierte er nur das Fenster und Knöpfe in der Ausgabe schienen tot).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var forwardsScrolling = false
    var onDoubleClick: (() -> Void)?
    var designWidth: CGFloat?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { onDoubleClick?() }
    }

    /// Zusatzfenster: Seite proportional verkleinern, wenn das Fenster schmaler als die Ausgabe ist.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let designWidth, designWidth > 0, newSize.width > 0 {
            let zoom = min(1, newSize.width / designWidth)
            if abs(pageZoom - zoom) > 0.005 { pageZoom = zoom }
        }
    }
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
