import Foundation

/// Ein Textabsatz aus einer Quelle.
nonisolated struct Passage: Equatable, Sendable {
    let sourceKey: String
    let index: Int
    var text: String
    var score: Double = 0
}

/// Absatz-Zerlegung und Keyword-Relevanz (BM25) – Port aus PdfAndDocs (`research/rank.py`,
/// `verify_retrieval.py`). Läuft ohne Modell und ohne Netzwerk.
nonisolated enum PassageRanker {

    // MARK: Zerlegen

    /// Satzbewusste Stücke von etwa `target` Zeichen: erst Absätze, lange Absätze an Satzenden
    /// geteilt; sehr kurze Fragmente (Überschriften, Listenstummel) werden mit dem nächsten Stück
    /// verbunden, damit Überschriften Kontext tragen statt allein zu „gewinnen“.
    static func split(_ blocks: [String], target: Int) -> [String] {
        var pieces: [String] = []
        for raw in blocks {
            let block = raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            guard !block.isEmpty else { continue }
            if Double(block.count) <= Double(target) * 1.4 {
                pieces.append(block)
                continue
            }
            var current = ""
            for sentence in sentences(of: block) {
                if !current.isEmpty && current.count + sentence.count > target {
                    pieces.append(current)
                    current = ""
                }
                current = current.isEmpty ? sentence : current + " " + sentence
            }
            if !current.isEmpty { pieces.append(current) }
        }
        var merged: [String] = []
        for piece in pieces {
            if let last = merged.last, last.count < target / 4 {
                merged[merged.count - 1] = last + " " + piece
            } else {
                merged.append(piece)
            }
        }
        return merged
    }

    private static func sentences(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let characters = Array(text)
        for (i, ch) in characters.enumerated() {
            current.append(ch)
            if ".!?".contains(ch), i + 1 < characters.count, characters[i + 1] == " " {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { result.append(current.trimmingCharacters(in: .whitespaces)) }
        return result
    }

    // MARK: Tokens

    static let stopwords: Set<String> = Set("""
    der die das den dem des ein eine einer eines einen einem und oder mit bei für von zur zum über unter nach vor aus auf \
    ist sind wie was wer welche welcher welches nicht auch als bis durch gegen ohne wird werden wurde hat haben kann können \
    soll sollte muss ab seit sowie bzw dass diese dieser dieses denn noch nur sehr im in an es sich man zu um so wenn dann \
    the and for with from what how which are into is of to in on at by an be or as it this that these those was were does \
    erkläre erklär erklären bitte kurz einfach
    """.split(whereSeparator: { $0.isWhitespace }).map(String.init))

    /// Kleinbuchstaben, Diakritika-unabhängig, Stoppwörter raus, einfaches Suffix-Stemming
    /// (Deutsch/Englisch), damit „Mitochondrien“/„Mitochondrium“ oder „enzymes“/„enzyme“ treffen.
    static func tokens(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
        var result: [String] = []
        var current = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                result.append(current); current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
            .filter { $0.count >= 2 && !stopwords.contains($0) }
            .map(stem)
    }

    private static let suffixes = ["ungen", "ierung", "heiten", "keiten", "ionen", "ern", "ung", "ien", "ium", "en", "er", "es", "ing", "ed", "e", "n", "s"]

    static func stem(_ word: String) -> String {
        guard word.count > 5, !word.allSatisfy(\.isNumber) else { return word }
        for suffix in suffixes where word.hasSuffix(suffix) && word.count - suffix.count >= 4 {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    // MARK: BM25

    static func bm25(documents: [[String]], query: [String], k1: Double = 1.5, b: Double = 0.75) -> [Double] {
        guard !documents.isEmpty else { return [] }
        let avgdl = Double(documents.reduce(0) { $0 + $1.count }) / Double(documents.count)
        var df: [String: Int] = [:]
        for doc in documents { for term in Set(doc) { df[term, default: 0] += 1 } }
        let n = Double(documents.count)
        let uniqueQuery = Array(Set(query))
        return documents.map { doc in
            var tf: [String: Int] = [:]
            for term in doc { tf[term, default: 0] += 1 }
            let norm = k1 * (1 - b + b * Double(doc.count) / max(1e-9, avgdl))
            var score = 0.0
            for term in uniqueQuery {
                guard let freq = tf[term], let docFreq = df[term] else { continue }
                let idf = log(1 + (n - Double(docFreq) + 0.5) / (Double(docFreq) + 0.5))
                score += idf * Double(freq) * (k1 + 1) / (Double(freq) + norm)
            }
            return score
        }
    }

    /// Anteil der Suchbegriffe, die im Absatz vorkommen (0…1) – Mindestfilter „die gesuchten
    /// Keywords kommen wirklich vor“.
    static func coverage(of passage: [String], query: [String]) -> Double {
        let q = Set(query)
        guard !q.isEmpty else { return 0 }
        return Double(q.intersection(passage).count) / Double(q.count)
    }

    /// 1 für Fließtext, kleiner für Schlagwort-Listen, Autorenzeilen, Menüreste: Diese sind für
    /// BM25 „keyword-dicht“, erklären aber nichts (Live-Test 12.10.: PubMed-MeSH-Liste auf Platz 1).
    static func proseQuality(_ text: String) -> Double {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 8 else { return 0.5 }
        let sentenceEnds = text.filter { ".!?:".contains($0) }.count
        let lowercaseWords = words.filter { $0.first?.isLowercase == true }.count
        let lowercaseShare = Double(lowercaseWords) / Double(words.count)
        var quality = 1.0
        if sentenceEnds == 0 { quality *= 0.6 }
        if lowercaseShare < 0.2 { quality *= 0.6 }   // fast nur Großgeschriebenes: Listen, Namen, Titel
        if text.contains("......") || text.contains("…………") { quality *= 0.3 }   // Inhaltsverzeichnis
        let separators = text.filter { ",|;".contains($0) }.count
        if Double(separators) / Double(words.count) > 0.3 { quality *= 0.5 }   // Schlagwort-/Tabellenlisten
        return quality
    }

    /// Grobe Token-Schätzung (≈ 4 Zeichen pro Token).
    static func estimatedTokens(_ text: String) -> Int { text.count / 4 + 1 }
}
