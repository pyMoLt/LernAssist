import Foundation

/// Konfiguration der Recherche-Tools, vom ViewModel bei jeder Einstellungsänderung gesetzt.
struct ResearchToolConfiguration {
    var settings = ResearchSettings()
    var searxngURL = ""
    var reranker: Reranker?
    var exaAPIKey = ""
    var maxBrowseCharacters = 10_000

    func pipeline() -> WebResearchPipeline {
        WebResearchPipeline(settings: settings, searxngURL: searxngURL, reranker: reranker, exaAPIKey: exaAPIKey)
    }
}

enum ToolArguments {
    static func object(_ arguments: String) -> [String: Any] {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    static func string(_ json: [String: Any], _ key: String) -> String {
        (json[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func nonNegativeInt(_ json: [String: Any], _ key: String) -> Int? {
        if let number = json[key] as? NSNumber { return max(0, number.intValue) }
        if let string = json[key] as? String, let value = Int(string.trimmingCharacters(in: .whitespaces)) { return max(0, value) }
        return nil
    }
}

// MARK: - web_search

/// Websuche als „Deep-Tool“: Das Modell formuliert nur die Anfrage. Die App fragt mehrere
/// Quellen, lädt Volltexte, rankt Absätze (BM25, optional Reranker) und gibt nummerierte
/// Belege `[W1]…` zurück – statt einer Linkliste, mit der kleine Modelle wenig anfangen.
final class WebSearchTool: AppTool {
    let name = "web_search"
    let displayName = "Websuche"
    let description = """
Recherchiert im Web (SearXNG, Wikipedia, Fachdatenbanken) und liefert die relevantesten Textabsätze \
mit Quellen [W1], [W2] …. Nutze es für Fakten, die du nicht sicher weißt, für Zahlen, Definitionen, \
Leitlinien und aktuelle Informationen. Formuliere eine kurze, präzise Suchanfrage (3–8 Wörter, \
Fachbegriffe). Zitiere die Belege in deiner Antwort mit [W#]. Nicht nutzen für einfache Rechnungen \
oder Dinge, die du sicher weißt.
"""
    let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "Kurze Suchanfrage mit Fachbegriffen, z. B. „Citratzyklus Regulation Enzyme“"]
        ],
        "required": ["query"]
    ]
    var isEnabled: Bool = true
    var configuration = ResearchToolConfiguration()

    /// Alte Einstellung, weiter genutzt vom ViewModel.
    var searxngURL: String {
        get { configuration.searxngURL }
        set { configuration.searxngURL = newValue }
    }

    func run(arguments: String, sessionID: String?) async -> ToolResult {
        let query = ToolArguments.string(ToolArguments.object(arguments), "query")
        guard !query.isEmpty else {
            return .failure("Fehler: Ungültige Tool-Argumente – erwartet: {\"query\": \"...\"}.")
        }
        let result = await configuration.pipeline().run(query)
        if result.passages.isEmpty, result.consultedSources.isEmpty || result.notes.count >= result.consultedSources.count {
            // Alle Quellen fehlgeschlagen (nicht: „nichts gefunden“) → als Fehler melden.
            let detail = result.notes.isEmpty ? "Keine Quelle aktiviert oder erreichbar." : result.notes.joined(separator: "\n")
            return .failure("Suche fehlgeschlagen:\n\(detail)", kind: .transient)
        }
        return ToolResult(content: ToolPromptHelpers.externalContent(result.modelText),
                          source: result.passages.first?.url)
    }
}

// MARK: - browse_url

/// Liest eine konkrete Webseite als reinen Text (ohne HTML, Skripte, Navigation, Metadaten).
/// Mit `focus` kommen nur die passenden Absätze zurück; sonst der Text abschnittsweise.
final class BrowseURLTool: AppTool {
    let name = "browse_url"
    let displayName = "URL lesen"
    let description = """
Liest eine bestimmte Webseite oder ein PDF als bereinigten Text. Mit `focus` (worum es dir geht) \
bekommst du nur die passenden Absätze – empfohlen bei langen Seiten. Ohne `focus` kommt der Text \
abschnittsweise; für den nächsten Abschnitt rufe dieselbe URL mit dem genannten `offset` erneut auf. \
Nutze es für Links des Nutzers oder um einen Beleg aus der Websuche genauer zu lesen.
"""
    let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "url": ["type": "string", "description": "Vollständige URL (https://…)"],
            "focus": ["type": "string", "description": "Optional: Wonach du auf der Seite suchst, z. B. „Dosierung bei Niereninsuffizienz“"],
            "offset": ["type": "integer", "minimum": 0, "description": "Optional: Zeichenoffset für den nächsten Abschnitt (ohne focus)"]
        ],
        "required": ["url"]
    ]
    var isEnabled: Bool = true
    var configuration = ResearchToolConfiguration()

    var maxBrowseCharacters: Int {
        get { configuration.maxBrowseCharacters }
        set { configuration.maxBrowseCharacters = newValue }
    }

    private static let cache = DocumentCache()

    func run(arguments: String, sessionID: String?) async -> ToolResult {
        let args = ToolArguments.object(arguments)
        let urlString = ToolArguments.string(args, "url")
        let focus = ToolArguments.string(args, "focus")
        let offset = ToolArguments.nonNegativeInt(args, "offset") ?? 0

        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else {
            return .failure("Fehler: Ungültige URL '\(urlString)'. Nur http/https-URLs sind erlaubt.")
        }

        let document: ExtractedDocument
        do {
            document = try await load(url)
        } catch let error as WebFetchError {
            let kind: ToolErrorKind
            if case .httpStatus(let code) = error, code == 429 || (500...599).contains(code) { kind = .transient } else { kind = .fatal }
            return .failure("Fehler beim Laden: \(error.localizedDescription)", kind: kind)
        } catch {
            return .failure("Fehler beim Laden: \(error.localizedDescription)", kind: ToolErrorKind.classify(error))
        }

        let limit = max(500, min(maxBrowseCharacters, 100_000))
        let header = [document.title.isEmpty ? nil : "Titel: \(document.title)",
                      "URL: \(document.url)",
                      document.published.map { "Datum: \($0.prefix(10))" }].compactMap { $0 }.joined(separator: "\n")

        if !focus.isEmpty {
            let pieces = PassageRanker.split(document.blocks, target: configuration.settings.passageChars)
            let queryTokens = PassageRanker.tokens(focus)
            var scores = zip(PassageRanker.bm25(documents: pieces.map(PassageRanker.tokens), query: queryTokens), pieces)
                .map { $0 * PassageRanker.proseQuality($1) }
            if configuration.settings.rerankerMode == .auto, let reranker = configuration.reranker, !pieces.isEmpty {
                let window = Array(pieces.indices.sorted { scores[$0] > scores[$1] }.prefix(60))
                if let rerank = try? await reranker.scores(query: focus, documents: window.map { pieces[$0] }) {
                    var combined = Array(repeating: -1.0, count: pieces.count)
                    for (position, index) in window.enumerated() { combined[index] = rerank[position] * PassageRanker.proseQuality(pieces[index]) }
                    scores = combined
                }
            }
            var used = 0
            var chosen: [(Int, String)] = []
            for index in pieces.indices.sorted(by: { scores[$0] > scores[$1] }) where scores[index] > 0 {
                guard used + pieces[index].count <= limit, chosen.count < 10 else { break }
                used += pieces[index].count
                chosen.append((index, pieces[index]))
            }
            chosen.sort { $0.0 < $1.0 } // Lesereihenfolge
            let body = chosen.isEmpty
                ? "Zu „\(focus)“ steht auf dieser Seite nichts Passendes. Erster Abschnitt:\n\n" + String(document.text.prefix(min(limit, 2_000)))
                : chosen.map(\.1).joined(separator: "\n\n[…]\n\n")
            return ToolResult(content: ToolPromptHelpers.externalContent(header + "\n\n" + body), source: document.url)
        }

        let slice = WebContentService.sliceContent(document.text, offset: offset, maxCharacters: limit)
        return ToolResult(content: ToolPromptHelpers.externalContent(header + "\n\n" + slice), source: document.url)
    }

    /// Abruf mit Cache. Bei zu wenig Text (JavaScript-Seiten) wird die Seite in einem unsichtbaren
    /// WebView gerendert – nach derselben SSRF-Prüfung.
    private func load(_ url: URL) async throws -> ExtractedDocument {
        if let cached = await Self.cache.get(url.absoluteString) { return cached }
        let settings = configuration.settings
        let fetcher = WebFetcher(timeout: settings.fetchTimeout, maxBytes: Int(settings.maxDownloadMB * 1_048_576))
        var document: ExtractedDocument?
        var lastError: Error?
        do {
            let page = try await fetcher.fetch(url)
            document = try ContentExtractor.extract(page)
        } catch let error as WebFetchError {
            if case .blockedAddress = error { throw error }
            if case .invalidURL = error { throw error }
            lastError = error
        } catch {
            lastError = error
        }

        if document == nil || (document.map { $0.characterCount < 400 || ContentExtractor.looksLikeBotPage($0) } ?? true) {
            try await WebFetcher.validate(url)
            if let rendered = try? await WebContentService.shared.fetchContent(from: url, offset: 0, maxCharacters: 400_000),
               rendered.count > (document?.characterCount ?? 0) {
                document = ExtractedDocument(title: document?.title ?? "", url: url.absoluteString,
                                             published: document?.published, blocks: ContentExtractor.paragraphs(of: rendered.replacingOccurrences(of: "\n", with: "\n\n")))
            }
        }
        guard let document, document.characterCount > 0 else {
            throw lastError ?? WebFetchError.unsupportedContent("leere Seite")
        }
        await Self.cache.put(document, for: url.absoluteString)
        return document
    }
}

/// Kurzlebiger Seiten-Cache für browse_url (Abschnitte/Fokus ohne erneuten Abruf).
actor DocumentCache {
    private var entries: [String: (document: ExtractedDocument, expires: Date)] = [:]

    func get(_ key: String) -> ExtractedDocument? {
        guard let entry = entries[key], entry.expires > Date() else { entries[key] = nil; return nil }
        return entry.document
    }

    func put(_ document: ExtractedDocument, for key: String) {
        entries = entries.filter { $0.value.expires > Date() }
        if entries.count > 30, let oldest = entries.min(by: { $0.value.expires < $1.value.expires })?.key { entries[oldest] = nil }
        entries[key] = (document, Date().addingTimeInterval(600))
    }
}
