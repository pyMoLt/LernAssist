import AppKit
import Foundation
import WebKit
import os

// MARK: - Lokale Bibliotheken für interaktive Ausgaben

/// Gängige JavaScript-Bibliotheken liegen in der App (Resources/libs, im Bundle flach als
/// `lib-<datei>`). Verweist eine Ausgabe auf eine bekannte CDN-Adresse, setzt die App die lokale
/// Kopie ein – die Ausgabe funktioniert offline und braucht keine Freigabe.
nonisolated enum HTMLLibraries {
    static let scheme = "lernassist-lib"
    /// Basisadresse der Ausgaben: Ohne eigene Herkunft blendet WebKit Fehlerdetails aus
    /// („Script error.“) – mit ihr gibt es Meldung und Zeile.
    static let baseURL = URL(string: "\(scheme)://artifact/index.html")

    /// Bekannte Bibliothek → lokale Datei. Reihenfolge zählt (spezifische Muster zuerst).
    /// `nil` als Datei = Verweis entfernen (Google Fonts: Systemschriften springen ein).
    private static let rules: [(pattern: String, file: String?)] = [
        (#"fonts\.(googleapis|gstatic)\.com"#, nil),
        (#"chartjs-(adapter|plugin)"#, ""),                       // Zusatzmodule: nicht lokal
        (#"(chart\.js|chart\.umd|/chart\.min\.js|chartjs)"#, "lib-chart.umd.min.js"),
        (#"(d3js\.org/d3\.v[67]|/d3@([67]|latest)|/libs/d3/[67]\.|/npm/d3/dist/)"#, "lib-d3.min.js"),
        (#"orbitcontrols\.js"#, "lib-OrbitControls.js"),
        (#"three(@0\.1[0-4]\d)?[^ ]*/three(\.min)?\.js|/three\.js/r1[0-4]\d/three(\.min)?\.js"#, "lib-three.min.js"),
        (#"p5\.sound"#, ""),
        (#"/p5(@[\d.]+)?/lib/p5(\.min)?\.js|/p5\.js/[\d.]+/p5(\.min)?\.js|/p5(\.min)?\.js"#, "lib-p5.min.js"),
        (#"anime(js)?(@3[\d.]*)?/(lib/)?anime(\.min)?\.js|/animejs/3[\d.]*/anime(\.min)?\.js"#, "lib-anime.min.js"),
        (#"gsap(@3[\d.]*)?/(dist/)?gsap(\.min)?\.js|/gsap/3[\d.]*/gsap(\.min)?\.js|tweenmax(\.min)?\.js"#, "lib-gsap.min.js"),
        (#"matter(-js)?(@[\d.]+)?/build/matter(\.min)?\.js|/matter-js/[\d.]+/matter(\.min)?\.js"#, "lib-matter.min.js"),
        (#"alpinejs"#, "lib-alpine.min.js"),
        (#"vue@3|/vue/3[\d.]*/|vue\.global(\.prod)?(\.min)?\.js"#, "lib-vue.global.prod.js"),
        (#"cytoscape(@[\d.]+)?/dist/cytoscape(\.min)?\.js|/cytoscape/[\d.]+/cytoscape(\.min)?\.js"#, "lib-cytoscape.min.js"),
        (#"vis-network"#, "lib-vis-network.min.js"),
        (#"leaflet(@1[\d.]*)?/dist/leaflet\.css|/leaflet/1[\d.]*/leaflet\.css"#, "lib-leaflet.css"),
        (#"leaflet(@1[\d.]*)?/dist/leaflet(-src)?\.js|/leaflet/1[\d.]*/leaflet(-src)?\.js"#, "lib-leaflet.js"),
        (#"lodash(@4[\d.]*)?/lodash(\.min)?\.js|/lodash\.js/4[\d.]*/lodash(\.min)?\.js"#, "lib-lodash.min.js"),
        (#"react-dom(@1[78][\d.]*)?/umd/react-dom\.(production|development)(\.min)?\.js"#, "lib-react-dom.production.min.js"),
        (#"/react(@1[78][\d.]*)?/umd/react\.(production|development)(\.min)?\.js"#, "lib-react.production.min.js"),
        (#"(font-?awesome|fontawesome-free)[^"' ]*\.css"#, "lib-fontawesome-all.min.css"),
        (#"cdn\.tailwindcss\.com"#, "lib-tailwind.js"),
        (#"katex[^"' ]*/auto-render(\.min)?\.js"#, "auto-render.min.js"),
        (#"katex[^"' ]*\.css"#, "katex.min.css"),
        (#"katex[^"' ]*\.js"#, "katex.min.js"),
        (#"mermaid[^"' ]*\.js"#, "mermaid.min.js"),
    ]

    /// Lokale Datei für eine externe Adresse: `.some(nil)` = Verweis weglassen, `nil` = unbekannt.
    static func localFile(for url: String) -> String?? {
        let lower = url.lowercased()
        for rule in rules where lower.range(of: rule.pattern, options: .regularExpression) != nil {
            if rule.file == "" { return nil }       // bewusst nicht lokal → Freigabe
            return .some(rule.file)
        }
        return nil
    }

    struct Rewrite: Equatable {
        var html: String
        /// Domains externer Ressourcen, die nicht lokal vorliegen (brauchen eine Freigabe).
        var unknownHosts: [String]
        /// Lokal ersetzte Bibliotheken (für das Tool-Ergebnis).
        var replaced: [String]
    }

    private static let tagPattern = try! NSRegularExpression(
        pattern: #"<\s*(script|link|img|iframe|video|audio|source)\b[^>]*>"#, options: [.caseInsensitive])
    private static let urlAttribute = try! NSRegularExpression(
        pattern: #"\b(src|href)\s*=\s*(["'])\s*((?:https?:)?//[^"']+)\2"#, options: [.caseInsensitive])
    private static let moduleImport = try! NSRegularExpression(
        pattern: #"(?:\bfrom\s*|\bimport\s*\(?\s*)(["'])((?:https?:)?//[^"']+)\1"#, options: [.caseInsensitive])

    /// Ersetzt bekannte CDN-Verweise durch lokale Kopien und sammelt die übrigen externen Domains.
    static func rewrite(_ html: String) -> Rewrite {
        var result = html
        var unknown: [String] = []
        var replaced: [String] = []
        let matches = tagPattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed()
        for match in matches {
            guard let tagRange = Range(match.range, in: result) else { continue }
            var tag = String(result[tagRange])
            guard let attr = urlAttribute.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
                  let urlRange = Range(attr.range(at: 3), in: tag) else { continue }
            let url = String(tag[urlRange])
            switch localFile(for: url) {
            case .some(.some(let file)):
                tag.replaceSubrange(urlRange, with: "\(scheme)://lib/\(file.hasSuffix(".css") ? "css/" : "")\(file)")
                // Prüfsummen (SRI) passen nicht zur lokalen Kopie.
                tag = tag.replacingOccurrences(of: #"\s(integrity|crossorigin)\s*=\s*(["'])[^"']*\2"#, with: "",
                                               options: [.regularExpression, .caseInsensitive])
                tag = tag.replacingOccurrences(of: #"\scrossorigin\b"#, with: "", options: [.regularExpression, .caseInsensitive])
                result.replaceSubrange(tagRange, with: tag)
                replaced.append(file.replacingOccurrences(of: "lib-", with: ""))
            case .some(.none):
                // Google Fonts: Verweis weglassen.
                result.replaceSubrange(tagRange, with: "")
            case .none:
                if let host = host(of: url) { unknown.append(host) }
            }
        }
        // ES-Module (`import … from "https://…"`) bleiben extern.
        for match in moduleImport.matches(in: result, range: NSRange(result.startIndex..., in: result)) {
            if let range = Range(match.range(at: 2), in: result), let host = host(of: String(result[range])) {
                unknown.append(host)
            }
        }
        var seen = Set<String>()
        return Rewrite(html: result, unknownHosts: unknown.filter { seen.insert($0).inserted },
                       replaced: Array(Set(replaced)).sorted())
    }

    static func host(of url: String) -> String? {
        let full = url.hasPrefix("//") ? "https:" + url : url
        return URL(string: full)?.host?.lowercased()
    }
}

/// Liefert die lokalen Bibliotheken unter `lernassist-lib://…/<datei>` aus dem App-Bundle.
final class LibrarySchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let name = url.lastPathComponent
        let candidates = name.hasPrefix("lib-") ? [name] : ["lib-" + name, name]
        guard let file = candidates.lazy.compactMap({ Self.bundleURL(for: $0) }).first,
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": Self.mimeType(for: name),
                                                      "Access-Control-Allow-Origin": "*"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private static func bundleURL(for name: String) -> URL? {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        return Bundle.main.url(forResource: base, withExtension: ext)
    }

    static func mimeType(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "js": "text/javascript"
        case "css": "text/css"
        case "woff2": "font/woff2"
        case "woff": "font/woff"
        case "ttf": "font/ttf"
        case "png": "image/png"
        default: "application/octet-stream"
        }
    }
}

// MARK: - Freigaben für externe Bibliotheken

/// Freigabe-Dialog für externe Bibliotheken in HTML-Ausgaben (eigene Liste, getrennt von den
/// Python-Domains). Nur Skripte, Styles, Schriften und Bilder dieser Domain – Netzabfragen
/// (`fetch`, XHR) bleiben gesperrt.
@MainActor
final class HTMLLibraryPermissions {
    static let shared = HTMLLibraryPermissions()

    var allowedDomains: () -> [String] = { [] }
    var addAllowedDomain: (String) -> Void = { _ in }

    func isAllowed(host: String) -> Bool {
        allowedDomains().contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Fragt einmal für alle noch nicht freigegebenen Domains. Liefert die erlaubten Domains
    /// oder nil, wenn der Nutzer ablehnt.
    func requestPermission(hosts: [String]) -> [String]? {
        let pending = hosts.filter { !isAllowed(host: $0) }
        guard !pending.isEmpty else { return hosts }
        if AppStorageLocation.isRunningUnitTests { return nil }
        let alert = NSAlert()
        alert.messageText = L("Interaktive Ausgabe möchte Bibliotheken laden")
        alert.informativeText = L("""
        Die Ausgabe des Modells verweist auf Dateien von

        \(pending.joined(separator: "\n"))

        Erlaubt werden nur Skripte, Styles, Schriften und Bilder dieser Adressen. Die Ausgabe kann \
        keine Daten senden oder abrufen.
        """)
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("Einmal erlauben"))
        alert.addButton(withTitle: L("Immer erlauben"))
        alert.addButton(withTitle: L("Ablehnen"))
        switch ModalActivity.run({ alert.runModal() }) {
        case .alertFirstButtonReturn:
            return hosts
        case .alertSecondButtonReturn:
            pending.forEach(addAllowedDomain)
            return hosts
        default:
            return nil
        }
    }
}

// MARK: - Fehlerbrücke, Härtung, Auto-Korrektur

nonisolated enum HTMLArtifactRuntime {
    static let errorHandlerName = "artifactError"

    /// Meldet Skriptfehler, abgelehnte Promises, console.error und nicht ladbare Ressourcen an die App.
    static let errorBridgeScript = """
    (function() {
      var sent = 0, seen = {};
      function post(msg) {
        if (!msg || sent >= 20 || seen[msg]) { return; }
        seen[msg] = true; sent++;
        try { window.webkit.messageHandlers.\(errorHandlerName).postMessage(String(msg).slice(0, 400)); } catch (e) {}
      }
      window.addEventListener('error', function(e) {
        if (e && e.target && e.target !== window && (e.target.src || e.target.href)) {
          post('Ressource nicht geladen: ' + (e.target.src || e.target.href));
          return;
        }
        post((e.message || 'Fehler') + (e.lineno ? ' (Zeile ' + e.lineno + ')' : ''));
      }, true);
      window.addEventListener('unhandledrejection', function(e) {
        var r = e && e.reason;
        post('Unbehandelte Promise-Ablehnung: ' + (r && r.message ? r.message : String(r)));
      });
      var original = console.error;
      console.error = function() {
        try { post(Array.prototype.map.call(arguments, function(a) { return a && a.message ? a.message : String(a); }).join(' ')); } catch (e) {}
        return original.apply(console, arguments);
      };
    })();
    """

    /// Content-Security-Policy: inline JS/CSS, lokale Bibliotheken, freigegebene Domains – kein Netz.
    static func contentSecurityPolicy(allowedHosts: [String]) -> String {
        let hosts = allowedHosts.map { "https://\($0)" }.joined(separator: " ")
        let lib = "\(HTMLLibraries.scheme):"
        let extra = hosts.isEmpty ? "" : " " + hosts
        return "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval' \(lib)\(extra); "
            + "style-src 'unsafe-inline' \(lib)\(extra); img-src data: blob: \(lib)\(extra); "
            + "font-src data: blob: \(lib)\(extra); connect-src 'none'; media-src data: blob:; worker-src blob:;"
    }

    /// Setzt die CSP als erstes Element in den <head> (nur dort wirkt sie).
    static func hardened(_ html: String, allowedHosts: [String] = []) -> String {
        let csp = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy(allowedHosts: allowedHosts))\">"
        // Exakt auf das head-Tag matchen – "<header>" darf nicht treffen (Audit 2026-10-12, H-1).
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
        let doctype = html.range(of: #"^\s*<!doctype[^>]*>"#, options: [.regularExpression, .caseInsensitive])
        var result = html
        result.insert(contentsOf: "<head>" + csp + "</head>", at: doctype?.upperBound ?? result.startIndex)
        return result
    }

    /// Zur Anzeige: lokale Bibliotheken einsetzen und härten.
    static func renderable(_ html: String, allowedHosts: [String]) -> String {
        hardened(HTMLLibraries.rewrite(html).html, allowedHosts: allowedHosts)
    }

    // MARK: Auto-Korrektur

    private static let inlineHeadScript = try! NSRegularExpression(
        pattern: #"<script(?![^>]*\b(src|type\s*=\s*["']?module|defer|async)\b)[^>]*>[\s\S]*?</script>"#,
        options: [.caseInsensitive])

    /// Häufigster Fehler kleiner Modelle: Skripte im <head> greifen auf Elemente zu, die es beim
    /// Ausführen noch nicht gibt („null is not an object“). Verschiebt solche Skripte ans Ende des
    /// <body>. Liefert nil, wenn nichts zu verschieben war.
    static func moveHeadScriptsToBodyEnd(_ html: String) -> String? {
        guard let headOpen = html.range(of: #"<head(\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]),
              let headClose = html.range(of: "</head>", options: .caseInsensitive, range: headOpen.upperBound..<html.endIndex)
        else { return nil }
        let head = String(html[headOpen.upperBound..<headClose.lowerBound])
        let scripts = inlineHeadScript.matches(in: head, range: NSRange(head.startIndex..., in: head))
            .compactMap { Range($0.range, in: head).map { String(head[$0]) } }
        guard !scripts.isEmpty else { return nil }
        var newHead = head
        scripts.forEach { if let r = newHead.range(of: $0) { newHead.removeSubrange(r) } }
        var result = html
        result.replaceSubrange(headOpen.upperBound..<headClose.lowerBound, with: newHead)
        let block = scripts.joined(separator: "\n")
        if let bodyClose = result.range(of: "</body>", options: [.caseInsensitive, .backwards]) {
            result.insert(contentsOf: block + "\n", at: bodyClose.lowerBound)
        } else {
            result += "\n" + block
        }
        return result
    }

    /// Fehler, die nach dem Verschieben der Head-Skripte verschwinden könnten.
    static func looksLikeEarlyDOMAccess(_ errors: [String]) -> Bool {
        errors.contains { $0.contains("null is not an object") || $0.contains("Cannot read properties of null")
            || $0.contains("undefined is not an object (evaluating 'document.") }
    }
}

// MARK: - Probelauf vor der Antwort an das Modell

/// Lädt eine HTML-Ausgabe kurz unsichtbar und sammelt Skriptfehler – sie gehen im Tool-Ergebnis
/// an das Modell, das dann eine korrigierte Fassung schicken kann (wie beim Python-Traceback).
@MainActor
final class HTMLPreflight: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private var errors: [String] = []
    private var finished: CheckedContinuation<Void, Never>?
    private var webView: WKWebView?

    static func errors(in html: String, allowedHosts: [String], settle: TimeInterval = 0.8,
                       timeout: TimeInterval = 5) async -> [String] {
        let probe = HTMLPreflight()
        return await probe.run(html: HTMLArtifactRuntime.renderable(html, allowedHosts: allowedHosts),
                               settle: settle, timeout: timeout)
    }

    private func run(html: String, settle: TimeInterval, timeout: TimeInterval) async -> [String] {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(LibrarySchemeHandler(), forURLScheme: HTMLLibraries.scheme)
        config.userContentController.addUserScript(WKUserScript(source: HTMLArtifactRuntime.errorBridgeScript,
                                                                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.add(WeakMessageHandler(self), name: HTMLArtifactRuntime.errorHandlerName)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        view.navigationDelegate = self
        webView = view
        view.loadHTMLString(html, baseURL: HTMLLibraries.baseURL)
        await withCheckedContinuation { continuation in
            finished = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish() }
        }
        // Kurz laufen lassen: Fehler beim Start (setTimeout, requestAnimationFrame) kommen etwas später.
        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: HTMLArtifactRuntime.errorHandlerName)
        webView = nil
        return errors
    }

    private func finish() {
        finished?.resume()
        finished = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        decisionHandler(["http", "https", "file", "ftp"].contains(scheme ?? "") ? .cancel : .allow)
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            if let text = message.body as? String, errors.count < 8 { errors.append(text) }
        }
    }
}

/// Verhindert den Retain-Zyklus WKUserContentController → Handler.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

// MARK: - Ausgaben als Datei

/// Jede interaktive Ausgabe liegt zusätzlich als `.html` im Arbeitsordner des Chats
/// (CodingOutput/<Chat>/Ausgaben) – zum Öffnen im Browser oder Finder. Gespeichert wird die
/// Fassung des Modells: im Browser laden CDN-Verweise ganz normal aus dem Netz.
nonisolated enum HTMLArtifactFiles {
    static let folderName = "Ausgaben"

    static func directory(sessionID: String) -> URL {
        CodingEnvironment.shared.outputDirectory
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    static func fileURL(messageID: UUID, sessionID: String) -> URL {
        directory(sessionID: sessionID).appendingPathComponent("ausgabe-\(messageID.uuidString.prefix(8).lowercased()).html")
    }

    /// Schreibt die Datei (falls nötig) und liefert ihren Pfad.
    @discardableResult
    static func save(_ html: String, messageID: UUID, sessionID: String) -> URL? {
        let url = fileURL(messageID: messageID, sessionID: sessionID)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? String(contentsOf: url, encoding: .utf8)) != html {
                try Data(html.utf8).write(to: url, options: .atomic)
            }
            return url
        } catch {
            AppLog.services.error("Ausgabe konnte nicht gespeichert werden: \(error.localizedDescription)")
            return nil
        }
    }
}
