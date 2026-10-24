import Foundation

/// Repariert ungültiges JSON in Tool-Argumenten kleiner Modelle, bevor das Tool läuft (nach dem
/// Vorbild von `jsonrepair`): Code-Fences, Kommentare, Python-Literale, einfache Anführungszeichen,
/// Kommas am Ende, rohe Zeilenumbrüche in Strings und abgeschnittenes JSON (offene Strings und
/// Klammern werden geschlossen). Gültiges JSON bleibt unverändert.
nonisolated enum ToolArgumentRepair {

    static func isValid(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }

    /// Reparierte Fassung oder nil, wenn nichts zu retten ist.
    static func repair(_ raw: String) -> String? {
        if isValid(raw) { return raw }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: #"^```[a-zA-Z]*\s*"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        }
        // Text vor dem ersten { (z. B. „Hier die Argumente:“).
        if let brace = text.firstIndex(of: "{"), brace != text.startIndex { text = String(text[brace...]) }
        guard text.hasPrefix("{") else { return nil }
        let repaired = normalize(text)
        return isValid(repaired) ? repaired : nil
    }

    /// Ein Durchlauf über die Zeichen mit Zustand (in String / nicht), damit nur außerhalb von
    /// Strings ersetzt wird.
    private static func normalize(_ text: String) -> String {
        var out = ""
        var stack: [Character] = []
        var inString = false
        var quote: Character = "\""
        var escaped = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped {
                    escaped = false
                    out.append(c)
                } else if c == "\\" {
                    escaped = true
                    out.append(c)
                } else if c == quote {
                    inString = false
                    out.append("\"")
                } else if c == "\"" {             // " in einem '…'-String
                    out.append("\\\"")
                } else if c == "\n" {
                    out.append("\\n")
                } else if c == "\r" {
                    out.append("\\r")
                } else if c == "\t" {
                    out.append("\\t")
                } else {
                    out.append(c)
                }
                i += 1
                continue
            }
            switch c {
            case "\"", "'":
                inString = true
                quote = c
                out.append("\"")
            case "{", "[":
                stack.append(c == "{" ? "}" : "]")
                out.append(c)
            case "}", "]":
                // Komma am Ende entfernen.
                while let last = out.last, last == "," || last.isWhitespace { out.removeLast() }
                if let expected = stack.last, expected == c { stack.removeLast() }
                out.append(c)
            case "/" where i + 1 < chars.count && chars[i + 1] == "/":
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            default:
                // Python-Literale außerhalb von Strings.
                let rest = String(chars[i..<min(chars.count, i + 5)])
                if let (word, json) = [("True", "true"), ("False", "false"), ("None", "null")].first(where: { rest.hasPrefix($0.0) }),
                   !(out.last.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false) {
                    out += json
                    i += word.count
                    continue
                }
                out.append(c)
            }
            i += 1
        }
        // Abgeschnitten: offenen String und Klammern schließen.
        if inString {
            if escaped { out.removeLast() }
            out.append("\"")
        }
        while let last = out.last, last == "," || last == ":" || last.isWhitespace { out.removeLast() }
        while let close = stack.popLast() { out.append(close) }
        return out
    }
}
