import Foundation

/// Konfiguration der Recherche-Tools, vom ViewModel bei jeder Einstellungsänderung gesetzt.
struct ResearchToolConfiguration {
    var settings = ResearchSettings()
    var searxngURL = ""
    /// Anmeldung am Such-Server (z. B. `Authorization: Bearer …`).
    var searxngHeaders: [String: String] = [:]
    var reranker: Reranker?
    var exaAPIKey = ""
    var braveAPIKey = ""
    var maxBrowseCharacters = 10_000

    func pipeline() -> WebResearchPipeline {
        var pipeline = WebResearchPipeline(settings: settings, searxngURL: searxngURL, reranker: reranker, exaAPIKey: exaAPIKey, braveAPIKey: braveAPIKey)
        pipeline.searxngHeaders = searxngHeaders
        return pipeline
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
Fachbegriffe). Zitiere die Belege in deiner Antwort mit [W#]. Belege können Abbildungen enthalten \
([B#] mit Beschreibung) – hilft eine zur Erklärung, schreibe [B#] allein in eine Zeile, und zwar dort, wo du über \
das Gezeigte sprichst (direkt vor oder nach dem Absatz, auf den sich das Bild bezieht); die App zeigt es dort an. \
Nicht nutzen für einfache Rechnungen oder Dinge, die du sicher weißt. Führe keine redundanten Folgesuchen durch, sobald die benötigten Fakten vorliegen.
"""
    let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "Kurze Suchanfrage mit Fachbegriffen, z. B. „Fast Fourier Transform Algorithmus“ oder „Citratzyklus Regulation“"]
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
        let status: [ToolArtifact] = (result.statuses.isEmpty ? [] : [.researchStatus(result.statuses)])
            + (result.phases.isEmpty ? [] : [.researchPhases(result.phases)])
        if result.passages.isEmpty, result.consultedSources.isEmpty || result.notes.count >= result.consultedSources.count {
            // Alle Quellen fehlgeschlagen (nicht: „nichts gefunden“) → als Fehler melden. Kein
            // automatisches Wiederholen mehr (Version 4.0): Ausgefallene und begrenzte Quellen
            // pausiert der Quellen-Zustand, ein sofortiger zweiter Versuch träfe sie wieder.
            let detail = result.notes.isEmpty ? "Keine Quelle aktiviert oder erreichbar." : result.notes.joined(separator: "\n")
            var failure = ToolResult.failure("Suche fehlgeschlagen:\n\(detail)")
            failure.artifacts = status
            return failure
        }
        return ToolResult(content: ToolPromptHelpers.externalContent(result.modelText),
                          source: result.passages.first?.url,
                          artifacts: (result.images.isEmpty ? [] : [.researchImages(result.images)]) + status)
    }
}

// MARK: - browse_url

/// Liest eine konkrete Webseite als reinen Text (ohne HTML, Skripte, Navigation, Metadaten).
/// Mit `focus` kommen nur die passenden Absätze zurück; sonst der Text abschnittsweise.
final class BrowseURLTool: AppTool {
    let name = "browse_url"
    let displayName = "URL lesen"
    let description = """
Liest eine bestimmte Webseite oder ein PDF als bereinigten Text. In den meisten Fällen genügt `focus`, \
um gezielt Informationen aus einem langen Text zu finden. Nur wenn du die Seite wirklich vollständig der \
Reihe nach lesen musst, nutze `offset`. Fehlen beide Parameter, wird automatisch die aktuelle Frage des Nutzers als `focus` verwendet. \
Nutze es für Links des Nutzers oder um einen Beleg aus der Websuche genauer zu lesen. Die Seite kann \
Abbildungen enthalten ([B#] mit Beschreibung) – hilft eine zur Erklärung, schreibe [B#] allein in eine Zeile, \
direkt vor oder nach dem Absatz, auf den sich das Bild bezieht.
"""
    let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "url": ["type": "string", "description": "Vollständige URL (https://…)"],
            "focus": ["type": "string", "description": "Optional: Wonach du auf der Seite suchst (Standard, z. B. „Dosierung bei Niereninsuffizienz“). In den meisten Fällen genügt focus."],
            "offset": ["type": "integer", "minimum": 0, "description": "Optional: Zeichenoffset für das fortlaufende Lesen der Reihe nach (nur wenn die Seite vollständig gelesen werden muss)"]
        ],
        "required": ["url"]
    ]
    var isEnabled: Bool = true
    var configuration = ResearchToolConfiguration()
    /// Liefert die aktuelle Frage des Nutzers für den automatischen Fokus-Modus
    var currentQuestionProvider: ((String?) -> String?)?

    /// Fehlen `focus` und `offset`, liest das Tool im Fokus-Modus mit der Nutzerfrage (siehe
    /// `automaticFocus`). Ein expliziter `offset` (auch 0) liest immer der Reihe nach.
    static func resolveFocusAndOffset(arguments: [String: Any], question: String?) -> (focus: String, offset: Int) {
        let rawFocus = ToolArguments.string(arguments, "focus")
        let rawOffset = ToolArguments.nonNegativeInt(arguments, "offset")
        if rawFocus.isEmpty && rawOffset == nil {
            return (automaticFocus(from: question ?? "") ?? "", 0)
        }
        return (rawFocus, rawOffset ?? 0)
    }

    /// Fokus aus der Nutzerfrage, wenn das Modell weder `focus` noch `offset` angibt. nil heißt
    /// der Reihe nach lesen: Besteht die Nachricht im Wesentlichen nur aus dem Link oder will der
    /// Nutzer die ganze Seite bzw. eine Zusammenfassung, ergäben Fokus-Ausschnitte nur Bruchstücke.
    static func automaticFocus(from question: String) -> String? {
        let withoutLinks = question.replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
        let text = withoutLinks.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: \.isLetter) }
        guard words.count >= 4 else { return nil }
        let wholePage = #"(?i)zusammenfass|fass\w* .*zusammen|ganze[nr]? (seite|artikel|text)|gesamte[nr]? (seite|artikel|text)|vollständig|komplett (lesen|durch)|summar|tl;?dr|was steht (da|dort|auf der seite|in dem artikel)"#
        if text.range(of: wholePage, options: .regularExpression) != nil { return nil }
        return String(text.prefix(500))
    }

    var maxBrowseCharacters: Int {
        get { configuration.maxBrowseCharacters }
        set { configuration.maxBrowseCharacters = newValue }
    }

    private static let cache = DocumentCache()

    func run(arguments: String, sessionID: String?) async -> ToolResult {
        let args = ToolArguments.object(arguments)
        let urlString = ToolArguments.string(args, "url")
        let (focus, offset) = Self.resolveFocusAndOffset(arguments: args,
                                                         question: currentQuestionProvider?(sessionID))

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
        // Abbildungen der Seite (höchstens 3), zur Frage bzw. zum Fokus gerankt.
        let images = await pageImages(of: document, query: focus.isEmpty ? (currentQuestionProvider?(sessionID) ?? document.title) : focus)
        let imageText = ResearchImages.modelText(for: images)
        let imageArtifacts: [ToolArtifact] = images.isEmpty ? [] : [.researchImages(images)]
        let header = [document.title.isEmpty ? nil : "Titel: \(document.title)",
                      "URL: \(document.url)",
                      document.published.map { "Datum: \($0.prefix(10))" }].compactMap { $0 }.joined(separator: "\n")

        if !focus.isEmpty {
            let pieces = PassageRanker.split(document.blocks, target: configuration.settings.passageChars)
            let queryTokens = PassageRanker.tokens(focus)
            var scores = zip(PassageRanker.bm25(documents: pieces.map(PassageRanker.tokens), query: queryTokens), pieces)
                .map { $0 * PassageRanker.proseQuality($1) }
            if configuration.settings.rerankerMode == .auto, let reranker = configuration.reranker, !pieces.isEmpty {
                let window = Array(pieces.indices.sorted { scores[$0] > scores[$1] }.prefix(max(1, configuration.settings.rerankerWindow)))
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
            return ToolResult(content: ToolPromptHelpers.externalContent(header + "\n\n" + body + imageText),
                              source: document.url, artifacts: imageArtifacts)
        }

        let slice = WebContentService.sliceContent(document.text, offset: offset, maxCharacters: limit)
        return ToolResult(content: ToolPromptHelpers.externalContent(header + "\n\n" + slice + imageText),
                          source: document.url, artifacts: imageArtifacts)
    }

    private func pageImages(of document: ExtractedDocument, query: String) async -> [ResearchImageRef] {
        let settings = configuration.settings
        guard settings.imagesEnabled, !document.images.isEmpty else { return [] }
        let picked = await ResearchImages.rank(document.images.map { (image: $0, pageTitle: document.title) }, query: query,
                                               reranker: settings.rerankerMode == .auto ? configuration.reranker : nil,
                                               limit: ResearchImages.maxPerPage + 2)
        guard !picked.isEmpty else { return [] }
        return await ResearchImages.downloadAll(picked, limit: ResearchImages.maxPerPage)
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
    /// Standard-Lebensdauer (Einstellungen → Tools → Erweitert). Vom Main-Thread gesetzt,
    /// im Actor gelesen – daher hinter einem Lock.
    nonisolated static var defaultDuration: TimeInterval {
        get { durationLock.lock(); defer { durationLock.unlock() }; return storedDuration }
        set { durationLock.lock(); storedDuration = newValue; durationLock.unlock() }
    }
    private static let durationLock = NSLock()
    nonisolated(unsafe) private static var storedDuration: TimeInterval = 600
    private var entries: [String: (document: ExtractedDocument, expires: Date)] = [:]

    func get(_ key: String) -> ExtractedDocument? {
        guard let entry = entries[key], entry.expires > Date() else { entries[key] = nil; return nil }
        return entry.document
    }

    func put(_ document: ExtractedDocument, for key: String, duration: TimeInterval? = nil) {
        let ttl = duration ?? Self.defaultDuration
        entries = entries.filter { $0.value.expires > Date() }
        if entries.count > 30, let oldest = entries.min(by: { $0.value.expires < $1.value.expires })?.key { entries[oldest] = nil }
        entries[key] = (document, Date().addingTimeInterval(ttl))
    }
}
