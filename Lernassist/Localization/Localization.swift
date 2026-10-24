import Foundation

// MARK: - Sprache der Oberfläche (Version 4)

/// Sprache der App-Oberfläche. Standard ist Englisch, Deutsch die zweite Sprache. Prompts und
/// Tool-Beschreibungen für das Modell sind davon unabhängig.
nonisolated enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case german = "de"

    var id: String { rawValue }

    /// Name in der eigenen Sprache (für den Umschalter).
    var nativeName: String {
        switch self {
        case .english: "English"
        case .german: "Deutsch"
        }
    }
}

/// Aktuelle Sprache und Übersetzungstabelle. Schlüssel sind die deutschen Texte im Code; die
/// englischen Fassungen liegen in `EnglishStrings.table`. Fehlt eine Übersetzung, bleibt der
/// deutsche Text stehen.
nonisolated enum Loc {
    nonisolated(unsafe) static var current: AppLanguage = .english

    static func translate(_ german: String) -> String {
        guard current == .english else { return german }
        return EnglishStrings.table[german] ?? german
    }
}

/// Text mit Platzhaltern: `L("\(count) Treffer")` wird als Vorlage „%@ Treffer“ übersetzt und
/// danach mit den Werten gefüllt – so funktionieren auch Texte mit Zahlen und Namen.
nonisolated struct LocalizedText: ExpressibleByStringInterpolation, Sendable {
    var key: String
    var arguments: [String]

    init(stringLiteral value: String) {
        key = value
        arguments = []
    }

    init(stringInterpolation: Interpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    struct Interpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []

        init(literalCapacity: Int, interpolationCount: Int) {}

        mutating func appendLiteral(_ literal: String) { key += literal }

        mutating func appendInterpolation<T>(_ value: T) {
            key += "%@"
            arguments.append(String(describing: value))
        }
    }
}

/// Übersetzt einen Oberflächentext in die gewählte Sprache.
nonisolated func L(_ text: LocalizedText) -> String {
    let template = Loc.translate(text.key)
    guard !text.arguments.isEmpty else { return template }
    var result = ""
    var arguments = text.arguments.makeIterator()
    var rest = Substring(template)
    while let range = rest.range(of: "%@") {
        result += rest[..<range.lowerBound]
        result += arguments.next() ?? ""
        rest = rest[range.upperBound...]
    }
    return result + rest
}

/// Übersetzt einen Text, der erst zur Laufzeit feststeht (z. B. Anzeigenamen aus Daten).
nonisolated func L(dynamic text: String) -> String {
    Loc.translate(text)
}
