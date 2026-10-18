import Foundation
import ImageIO

/// Ein Bild-Kandidat aus einer Quelle (Webseite, Wikipedia, Europe PMC).
nonisolated struct PageImage: Equatable, Sendable {
    var url: String
    var pageURL: String
    /// Bildunterschrift (figure/figcaption, Wikipedia, Abbildungslegende) – bevorzugt.
    var caption: String
    var alt: String
    var width: Int? = nil
    var height: Int? = nil

    /// Text, der das Bild beschreibt: Bildunterschrift, sonst Alt-Text.
    var describingText: String { caption.isEmpty ? alt : caption }
}

/// Abbildung, die das Modell mit [B#] zeigen kann. Liegt als Kopie im App-Speicher (offline-fest),
/// die Nummer ist im ganzen Chat eindeutig (siehe `ChatViewModel.renumberCitations`).
nonisolated struct ResearchImageRef: Codable, Equatable, Sendable {
    var number: Int
    var imageID: UUID
    var caption: String
    var sourceURL: String
    var pageURL: String
    var domain: String
}

/// Auswahl der Abbildungen für die Recherche: Filter (Herkunft, Format, Größe, Text), Rangfolge
/// gegen die Frage (BM25, mit Reranker falls an) und geprüftes Herunterladen.
nonisolated enum ResearchImages {
    static let maxPerPage = 3
    static let maxPerSearch = 6
    static let maxBytes = 8 * 1_048_576
    static let minWidth = 200
    static let minHeight = 150
    static let maxAspect = 4.5

    private static let blockedPath = try! NSRegularExpression(
        pattern: #"(logo|icon|favicon|avatar|banner|sprite|badge|button|pixel|tracking|spacer|emoji|flag_of|placeholder|loading|advert|(^|[/_.-])ads?([/_.-]|$))"#,
        options: [.caseInsensitive])
    private static let genericTexts: Set<String> = ["bild", "foto", "photo", "image", "picture", "grafik", "abbildung",
                                                    "logo", "icon", "thumbnail", "vorschaubild", "img"]

    // MARK: Filter

    /// Taugt der Kandidat überhaupt (vor dem Herunterladen)?
    static func isCandidate(_ image: PageImage) -> Bool {
        guard let url = URL(string: image.url), url.scheme?.lowercased() == "https",
              let host = url.host, !WebFetcher.isBlockedHostname(host.lowercased()) else { return false }
        let path = url.path.lowercased()
        if blockedPath.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil { return false }
        let ext = url.pathExtension.lowercased()
        // SVG nur als gerenderte PNG-Fassung (Wikimedia liefert …svg.png).
        if !ext.isEmpty, !["png", "jpg", "jpeg", "gif", "webp"].contains(ext) { return false }
        if let width = image.width, width > 0, width < minWidth { return false }
        if let height = image.height, height > 0, height < minHeight { return false }
        return isMeaningful(image.describingText)
    }

    /// Bildunterschrift bzw. Alt-Text mit Aussage: ein paar Wörter, kein Dateiname, kein Füllwort.
    static func isMeaningful(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: \.isLetter) }
        guard words.count >= 3 || trimmed.count >= 20 else { return false }
        if trimmed.range(of: #"^[\w\-]+\.(png|jpe?g|gif|webp|svg)$"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        // Platzhalter-Beschriftungen von Blogs und Foren („Bild zum Beitrag“, „Symbolbild“, „Featured image“).
        let placeholder = #"^(symbol|beitrags|titel|teaser|vorschau|header|artikel)?(bild|foto|grafik)( (zum|zu|des|vom|für den|für das) (beitrag|artikel|thema|post|text))?\b|^(featured|header|hero|cover) image|^image (for|of) (the )?(post|article)|^(bild|foto): ?[^ ]+$"#
        if trimmed.range(of: placeholder, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        return !genericTexts.contains(trimmed.lowercased())
    }

    // MARK: Thema der Frage

    /// Wörter, die nur „Bild bitte“ bedeuten – für die Textsuche und das Thema sind sie Rauschen.
    static let imageWords: Set<String> = [
        "abbildung", "abbildungen", "bild", "bilder", "diagramm", "diagramme", "schema", "schemata", "schemazeichnung",
        "zeichnung", "grafik", "graphik", "foto", "fotos", "skizze", "illustration", "darstellung", "uebersicht", "übersicht",
        "image", "images", "picture", "diagram", "figure", "figures", "drawing", "illustration", "png", "jpg", "svg",
        "wikimedia", "commons",
    ]

    /// Suchanfrage ohne Bildwörter (für Wikipedia/Europe PMC und das Thema der Abbildungen).
    static func textQuery(_ query: String) -> String {
        let words = query.split(whereSeparator: { $0.isWhitespace })
        let kept = words.filter { !imageWords.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
        return kept.isEmpty ? query : kept.joined(separator: " ")
    }

    /// Allgemeine Strukturwörter („Aufbau“, „Ablauf“ …) – sie sagen nichts über das Thema selbst.
    static let genericTopicWords: Set<String> = Set([
        "aufbau", "ablauf", "funktion", "funktionen", "funktionsweise", "struktur", "anatomie", "physiologie",
        "definition", "erklaerung", "erklärung", "mechanismus", "prozess", "schritte", "phasen", "einfach",
        "kurz", "grundlagen", "beispiel", "beispiele", "bedeutung", "wirkung", "structure", "function", "overview",
        "process", "steps", "anatomy", "physiology", "mechanism", "explained", "basics",
    ].flatMap { PassageRanker.tokens($0) })

    /// Themenbegriffe der Frage: ohne Bildwörter und allgemeine Strukturwörter.
    static func topicTerms(_ query: String) -> [String] {
        let all = PassageRanker.tokens(textQuery(query))
        let specific = all.filter { !genericTopicWords.contains($0) }
        return specific.isEmpty ? all : specific
    }

    /// Anteil der Themenbegriffe, die in Bildtext oder Seitentitel vorkommen (Wortanfang genügt:
    /// „Herz“ passt zu „Herzens“, „Herzklappe“).
    static func topicCoverage(of text: String, topic: [String]) -> Double {
        guard !topic.isEmpty else { return 1 }
        let words = PassageRanker.tokens(text)
        let hits = Set(topic).filter { term in words.contains { $0 == term || ($0.hasPrefix(term) && term.count >= 4) } }
        return Double(hits.count) / Double(Set(topic).count)
    }

    // MARK: Rangfolge

    /// Die besten Kandidaten zur Frage (Bildtext + Seitentitel). Mit Reranker zählt dessen Urteil.
    static func rank(_ candidates: [(image: PageImage, pageTitle: String)], query: String,
                     reranker: Reranker?, limit: Int = maxPerSearch) async -> [PageImage] {
        // Dubletten raus; die Grenze „3 pro Seite“ gilt erst nach dem Ranking.
        var seen = Set<String>()
        let usable = candidates.filter { isCandidate($0.image) && seen.insert($0.image.url).inserted }
        guard !usable.isEmpty else { return [] }
        // Das Thema muss passen: mindestens die Hälfte der Themenbegriffe (ohne Bildwörter).
        let topic = topicTerms(query)
        let onTopic = usable.filter { topicCoverage(of: $0.image.describingText + " " + $0.pageTitle, topic: topic) >= 0.5 }
        guard !onTopic.isEmpty else { return [] }
        let texts = onTopic.map { $0.image.describingText + " " + $0.pageTitle }
        let queryTokens = PassageRanker.tokens(textQuery(query))
        var scores = PassageRanker.bm25(documents: texts.map(PassageRanker.tokens), query: queryTokens)
        var threshold = 0.0001
        if let reranker, let rerank = try? await reranker.scores(query: textQuery(query), documents: texts), rerank.count == texts.count {
            scores = rerank
            threshold = 0.2
        }
        var perPage: [String: Int] = [:]
        return zip(onTopic, scores)
            .filter { $0.1 > threshold }
            .sorted { $0.1 > $1.1 }
            .filter { item in
                perPage[item.0.image.pageURL, default: 0] += 1
                return perPage[item.0.image.pageURL]! <= maxPerPage
            }
            .prefix(limit)
            .map(\.0.image)
    }

    // MARK: Herunterladen

    /// Lädt und prüft ein Bild (Format am Inhalt, Mindestgröße, Seitenverhältnis) und legt es im
    /// App-Speicher ab. nil = ungeeignet.
    static func download(_ image: PageImage, timeout: TimeInterval = 15) async -> ResearchImageRef? {
        guard let url = URL(string: image.url),
              let page = try? await WebFetcher(timeout: timeout, maxBytes: maxBytes, userAgent: SourceHTTP.apiUserAgent)
                .fetch(url, accept: "image/png,image/jpeg,image/gif,image/webp;q=0.9,*/*;q=0.1"),
              !page.wasTruncated, isValidImage(page.data) else { return nil }
        let id = UUID()
        do {
            try page.data.write(to: AppStorageLocation.imageFile(id: id), options: .atomic)
        } catch {
            return nil
        }
        let domain = URL(string: image.pageURL)?.host?.replacingOccurrences(of: "www.", with: "") ?? ""
        return ResearchImageRef(number: 0, imageID: id, caption: String(image.describingText.prefix(240)),
                                sourceURL: image.url, pageURL: image.pageURL, domain: domain)
    }

    /// Echtes Rasterbild (PNG/JPEG/GIF/WebP) mit Mindestgröße und ohne extremes Seitenverhältnis.
    static func isValidImage(_ data: Data) -> Bool {
        let kind = DataDownloader.classify(data.prefix(16)).kind
        guard ["PNG", "JPEG", "GIF", "RIFF (z. B. WebP)"].contains(kind),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        guard width >= minWidth, height >= minHeight else { return false }
        let aspect = Double(max(width, height)) / Double(max(1, min(width, height)))
        return aspect <= maxAspect
    }

    /// Lädt die gewählten Bilder parallel und gibt höchstens `limit` gültige zurück (Reihenfolge bleibt).
    static func downloadAll(_ images: [PageImage], limit: Int = maxPerSearch) async -> [ResearchImageRef] {
        var results: [(Int, ResearchImageRef)] = []
        await withTaskGroup(of: (Int, ResearchImageRef?).self) { group in
            for (index, image) in images.enumerated() {
                group.addTask { (index, await download(image)) }
            }
            for await (index, ref) in group { if let ref { results.append((index, ref)) } }
        }
        return results.sorted { $0.0 < $1.0 }.prefix(limit).enumerated().map { offset, item in
            var ref = item.1
            ref.number = offset + 1
            return ref
        }
    }

    /// Hinweise für das Modell: „[B1] Abbildung: … — domain“.
    static func modelText(for refs: [ResearchImageRef]) -> String {
        guard !refs.isEmpty else { return "" }
        let lines = refs.map { ref -> String in
            let caption = ref.caption.count > 140 ? String(ref.caption.prefix(140)) + "…" : ref.caption
            return "[B\(ref.number)] Abbildung: \(caption) — \(ref.domain)"
        }
        return "\n\nAbbildungen (optional: hilft eine zur Erklärung, schreibe [B#] allein in eine Zeile direkt vor oder nach dem Absatz, auf den sie sich bezieht):\n"
            + lines.joined(separator: "\n")
    }
}
