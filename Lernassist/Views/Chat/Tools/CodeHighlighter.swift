import SwiftUI

/// Schlanker Syntax-Highlighter (Farben wie VS Code „Dark+“) für Python, HTML/CSS/JS.
/// Bewusst nativ statt WebView: Der Code wächst beim Streamen mehrmals pro Sekunde – ein
/// WebView pro Tool-Karte wäre zu teuer, und das Ergebnis soll sofort sichtbar sein.
enum CodeHighlighter {
    enum Palette {
        static let background = Color(red: 0.118, green: 0.118, blue: 0.118)     // #1E1E1E
        static let gutter = Color(red: 0.522, green: 0.522, blue: 0.522)         // #858585
        static let text = Color(red: 0.831, green: 0.831, blue: 0.831)           // #D4D4D4
        static let keyword = Color(red: 0.337, green: 0.612, blue: 0.839)        // #569CD6
        static let control = Color(red: 0.773, green: 0.525, blue: 0.753)       // #C586C0
        static let string = Color(red: 0.808, green: 0.569, blue: 0.471)         // #CE9178
        static let number = Color(red: 0.710, green: 0.808, blue: 0.659)         // #B5CEA8
        static let comment = Color(red: 0.416, green: 0.600, blue: 0.333)        // #6A9955
        static let function = Color(red: 0.863, green: 0.863, blue: 0.667)       // #DCDCAA
        static let tag = Color(red: 0.337, green: 0.612, blue: 0.839)
        static let attribute = Color(red: 0.612, green: 0.863, blue: 0.996)     // #9CDCFE
        static let titleBar = Color(red: 0.196, green: 0.196, blue: 0.200)      // #323233
        static let terminal = Color(red: 0.094, green: 0.094, blue: 0.094)
        static let error = Color(red: 0.957, green: 0.278, blue: 0.278)
        static let success = Color(red: 0.302, green: 0.788, blue: 0.690)
    }

    private struct Rule {
        let regex: NSRegularExpression
        let color: Color
        let group: Int
    }

    private static func rule(_ pattern: String, _ color: Color, group: Int = 0, options: NSRegularExpression.Options = []) -> Rule {
        Rule(regex: try! NSRegularExpression(pattern: pattern, options: options), color: color, group: group)
    }

    private static let pythonRules: [Rule] = [
        rule(#"\b(def|class|lambda|import|from|as|global|nonlocal|None|True|False|and|or|not|in|is)\b"#, Palette.keyword),
        rule(#"\b(if|elif|else|for|while|return|yield|try|except|finally|with|raise|break|continue|pass|assert|async|await)\b"#, Palette.control),
        rule(#"\b([A-Za-z_][A-Za-z0-9_]*)\s*(?=\()"#, Palette.function, group: 1),
        rule(#"\b\d+(\.\d+)?([eE][-+]?\d+)?\b"#, Palette.number),
        rule(#"(?s)(\"\"\".*?(\"\"\"|$)|'''.*?('''|$))"#, Palette.string),
        rule(#"(f|r|b)?"([^"\\\n]|\\.)*"?|(f|r|b)?'([^'\\\n]|\\.)*'?"#, Palette.string),
        rule(#"#[^\n]*"#, Palette.comment),
    ]

    private static let webRules: [Rule] = [
        rule(#"\b(const|let|var|function|class|new|this|null|undefined|true|false|typeof|instanceof)\b"#, Palette.keyword),
        rule(#"\b(if|else|for|while|return|switch|case|break|continue|try|catch|finally|throw|await|async)\b"#, Palette.control),
        rule(#"\b([A-Za-z_$][A-Za-z0-9_$]*)\s*(?=\()"#, Palette.function, group: 1),
        rule(#"\b\d+(\.\d+)?\b"#, Palette.number),
        rule(#"</?([A-Za-z][A-Za-z0-9-]*)"#, Palette.tag, group: 1),
        rule(#"\s([a-zA-Z-:]+)(?==)"#, Palette.attribute, group: 1),
        rule(#""([^"\\\n]|\\.)*"?|'([^'\\\n]|\\.)*'?|`[^`]*`?"#, Palette.string),
        rule(#"(?s)<!--.*?(-->|$)|/\*.*?(\*/|$)|//[^\n]*"#, Palette.comment),
    ]

    /// Färbt den Code. Spätere Regeln (Strings, Kommentare) überschreiben frühere, damit
    /// Schlüsselwörter in Strings/Kommentaren nicht eingefärbt bleiben.
    static func highlight(_ code: String, language: String) -> AttributedString {
        var attributed = AttributedString(code)
        attributed.foregroundColor = Palette.text
        let rules = language.lowercased() == "python" ? pythonRules : webRules
        let ns = code as NSString
        let full = NSRange(location: 0, length: ns.length)
        for rule in rules {
            for match in rule.regex.matches(in: code, range: full) {
                let range = match.range(at: rule.group)
                guard range.location != NSNotFound, let swiftRange = Range(range, in: code),
                      let attrRange = Range(swiftRange, in: attributed) else { continue }
                attributed[attrRange].foregroundColor = rule.color
            }
        }
        return attributed
    }
}
