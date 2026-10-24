import Foundation

/// Liest aus einem (ggf. noch streamenden) Tool-Call und seinem Ergebnis die Teile, die die
/// Oberfläche zeigt: Titel, Argumente, Quellen, Code, Konsolenausgabe, Fehler.
struct ToolCallPresentation {
    let call: ToolCallInfo
    /// Einmal geparst statt bei jedem Zugriff (title, language, code … lasen sonst je neu).
    private let json: [String: Any]?
    /// Code und Sprache aus den (ggf. noch unvollständigen) Argumenten – zwischengespeichert,
    /// solange sich die Argumente nicht ändern. Beim Live-Streamen von Code wurde der Text sonst
    /// pro Neuaufbau mehrfach komplett gelesen (Version 4, Performance).
    private let parsed: Parsed

    final class Parsed {
        let json: [String: Any]?
        let rawCode: String
        let language: String
        init(json: [String: Any]?, rawCode: String, language: String) {
            self.json = json; self.rawCode = rawCode; self.language = language
        }
    }

    private static let cache: NSCache<NSString, Parsed> = {
        let cache = NSCache<NSString, Parsed>()
        cache.countLimit = 200
        return cache
    }()

    init(call: ToolCallInfo) {
        self.call = call
        let key = "\(call.id)#\(call.index ?? -1)#\(call.name)#\(call.arguments.utf8.count)" as NSString
        if let cached = Self.cache.object(forKey: key) {
            parsed = cached
        } else {
            let json = call.arguments.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            func value(_ k: String) -> String {
                if let v = json?[k] { return (v as? String) ?? (v as? NSNumber)?.stringValue ?? "" }
                return Self.partialString(for: k, in: call.arguments) ?? ""
            }
            let rawCode = call.name == "coding_sandbox" ? value("code") : ""
            let lang = value("language").lowercased()
            let language = lang.isEmpty
                ? (call.arguments.contains("<html") || call.arguments.contains("<!DOCTYPE") ? "html" : "python") : lang
            parsed = Parsed(json: json, rawCode: rawCode, language: language)
            Self.cache.setObject(parsed, forKey: key)
        }
        json = parsed.json
    }

    var isRunning: Bool { call.result == nil }
    /// Wegen des Tool-Rundenlimits nicht ausgeführt (ruhige Info statt Fehler).
    var isLimitReached: Bool { call.limitNote == .notExecuted }
    var isError: Bool { !isLimitReached && (call.result?.contains("<TOOL_ERROR>") == true || call.result?.hasPrefix("Nicht ausgeführt") == true) }
    /// HTML-Ausgabe angezeigt, der Probelauf hat aber Skriptfehler gemeldet – nur ein Hinweis am
    /// einzelnen Schritt, die Ausgabe selbst und die Gruppe bleiben ruhig.
    var hasScriptWarning: Bool { !isError && call.name == "coding_sandbox" && call.result?.hasPrefix(CodingTool.htmlScriptErrorPrefix) == true }

    var symbol: String {
        switch call.name {
        case "web_search":        return "magnifyingglass"
        case "browse_url":        return "globe"
        case "calculate":         return "function"
        case "coding_sandbox":    return language == "html" ? "play.rectangle" : "chevron.left.forwardslash.chevron.right"
        case "recall_screenshot": return "photo.on.rectangle.angled"
        case "quiz_card":         return "questionmark.bubble"
        default:                  return "wrench.and.screwdriver"
        }
    }

    /// Kurzer, verständlicher Titel („Websuche: …“) statt des technischen Tool-Namens.
    var title: String {
        switch call.name {
        case "web_search":
            let q = argument("query")
            return q.isEmpty ? L("Websuche") : L("Websuche: „\(q)“")
        case "browse_url":
            let host = URL(string: argument("url"))?.host?.replacingOccurrences(of: "www.", with: "") ?? argument("url")
            return host.isEmpty ? L("Webseite lesen") : L("Liest \(host)")
        case "calculate":
            let expression = argument("expression")
            return expression.isEmpty ? L("Rechnen") : L("Rechnet \(expression)")
        case "coding_sandbox":
            if isRunning, call.arguments.count > 10, code.isEmpty == false, !argumentsComplete { return language == "html" ? L("Schreibt Simulation …") : L("Schreibt Code …") }
            if isRunning { return language == "html" ? L("Erstellt Simulation") : L("Führt Python aus") }
            return language == "html" ? L("Interaktive Simulation") : L("Python-Ausführung")
        case "recall_screenshot":
            let n = argument("number")
            return n.isEmpty ? L("Holt vorherigen Screenshot") : L("Holt Screenshot #\(n)")
        case "quiz_card":
            return L("Abfragekarte")
        default:
            return call.name.isEmpty ? L("Tool") : call.name
        }
    }

    // MARK: Argumente (auch während des Streamings)

    var argumentsComplete: Bool { json != nil }

    func argument(_ key: String) -> String {
        if let value = json?[key] {
            if let s = value as? String { return s }
            if let n = value as? NSNumber { return n.stringValue }
        }
        return Self.partialString(for: key, in: call.arguments) ?? ""
    }

    var language: String { parsed.language }

    /// Code wie er ausgeführt wird: Nach dem Streamen bereinigt (Markdown-Zäune o. Ä.), damit
    /// Zeilennummern und Fehlerkontext zur angezeigten Fassung passen.
    var code: String {
        let raw = call.name == "coding_sandbox" ? parsed.rawCode : argument("code")
        guard argumentsComplete, call.name == "coding_sandbox" else { return raw }
        return language == "html" ? CodingTool.sanitizeHTMLCode(raw) : CodingEnvironment.sanitizePythonCode(raw)
    }

    var packages: [String] { (json?["install_packages"] as? [String]) ?? [] }

    /// Wert eines String-Feldes aus noch unvollständigem JSON (beim Streamen der Argumente).
    static func partialString(for key: String, in arguments: String) -> String? {
        guard let keyRange = arguments.range(of: "\"\(key)\""),
              let colon = arguments.range(of: ":", range: keyRange.upperBound..<arguments.endIndex),
              let open = arguments[colon.upperBound...].firstIndex(where: { !$0.isWhitespace }),
              arguments[open] == "\"" else { return nil }
        var result = ""
        var index = arguments.index(after: open)
        var escaping = false
        while index < arguments.endIndex {
            let ch = arguments[index]
            if escaping {
                switch ch {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": break
                case "u":
                    let hexEnd = arguments.index(index, offsetBy: 5, limitedBy: arguments.endIndex) ?? arguments.endIndex
                    let hex = arguments[arguments.index(after: index)..<hexEnd]
                    if hex.count == 4, let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) {
                        result.append(Character(scalar))
                        index = arguments.index(index, offsetBy: 4)
                    }
                default: result.append(ch)
                }
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else if ch == "\"" {
                return result
            } else {
                result.append(ch)
            }
            index = arguments.index(after: index)
        }
        return result
    }

    // MARK: Ergebnis

    /// Ergebnis ohne Tool-Fehler-Hülle und ohne den Untrusted-Wrapper der Webinhalte.
    var cleanedResult: String {
        guard var text = call.result else { return "" }
        text = text.replacingOccurrences(of: "<TOOL_ERROR>", with: "").replacingOccurrences(of: "</TOOL_ERROR>", with: "")
        if let start = text.range(of: "<EXTERNAL_CONTENT>"), let end = text.range(of: "</EXTERNAL_CONTENT>") {
            text = String(text[start.upperBound..<end.lowerBound])
        }
        if let guidance = text.range(of: "\n\nDer Tool-Aufruf ist fehlgeschlagen.") { text = String(text[..<guidance.lowerBound]) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct Source: Identifiable, Equatable {
        let number: String
        let title: String
        let url: String
        var id: String { number + url }
        var domain: String { URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url }
    }

    /// Quellen aus dem web_search-Ergebnis (`[W1] Titel — domain` + `URL: …`).
    var sources: [Source] {
        let lines = cleanedResult.components(separatedBy: "\n")
        var result: [Source] = []
        for (index, line) in lines.enumerated() where line.hasPrefix("[W") {
            guard let close = line.firstIndex(of: "]") else { continue }
            let number = String(line[line.index(after: line.startIndex)..<close])
            var title = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            if let dash = title.range(of: " — ", options: .backwards) { title = String(title[..<dash.lowerBound]) }
            let url = index + 1 < lines.count && lines[index + 1].hasPrefix("URL: ") ? String(lines[index + 1].dropFirst(5)) : ""
            result.append(Source(number: number, title: title, url: url))
        }
        return result
    }

    struct CodeRun {
        var output: String
        var exitCode: Int?
        var errorContext: String?
        var installLog: String?
    }

    /// Bestandteile eines coding_sandbox-Ergebnisses.
    var codeRun: CodeRun? {
        guard call.name == "coding_sandbox", call.result != nil else { return nil }
        let text = cleanedResult
        func section(after marker: String, until markers: [String]) -> String? {
            guard let start = text.range(of: marker) else { return nil }
            let rest = text[start.upperBound...]
            let afterHeader = rest.drop(while: { $0 != "\n" }).dropFirst()
            var end = afterHeader.endIndex
            for m in markers { if let r = afterHeader.range(of: m), r.lowerBound < end { end = r.lowerBound } }
            return String(afterHeader[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let enders = ["\n\nExit Code:", "\n\n--- BETROFFENE", "\n\n(", "\n\nAbbildungen (", "\n\nErkläre dem Nutzer", "\nKorrigiere den Fehler", "\nDas Skript wurde"]
        let output = section(after: "--- AUSGABE", until: enders) ?? (language == "html" ? "" : text)
        var exit: Int?
        if let r = text.range(of: "Exit Code: ") {
            exit = Int(text[r.upperBound...].prefix(while: { $0.isNumber || $0 == "-" }))
        } else if !isError {
            exit = 0
        }
        let context = section(after: "--- BETROFFENE CODEZEILEN ---", until: ["\nKorrigiere"])
        let install = section(after: "--- PIP INSTALL LOG ---", until: ["\n\n---"])
        return CodeRun(output: output, exitCode: exit, errorContext: context, installLog: install)
    }
}
