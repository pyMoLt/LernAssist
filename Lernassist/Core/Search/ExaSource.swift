import Foundation

/// Exa-Websuche über den gehosteten MCP-Server (`https://mcp.exa.ai/mcp`, Tool `web_search_exa`).
/// Ohne Key: kostenlose, rate-limitierte Stufe. Mit Key: Header `x-api-key`.
/// Wird von der Pipeline nur als Fallback gefragt (siehe `ResearchSettings.exaMinWebResults`).
nonisolated struct ExaSource: SearchSource {
    var apiKey: String = ""
    var id: ResearchSource { .exa }

    static let endpoint = URL(string: "https://mcp.exa.ai/mcp")!

    func search(_ query: String, limit: Int) async throws -> [SearchHit] {
        try await HostPacing.shared.waitTurn(host: Self.endpoint.host ?? "mcp.exa.ai")
        let headers = apiKey.isEmpty ? [:] : ["x-api-key": apiKey]
        let client = MCPHTTPClient(endpoint: Self.endpoint, headers: headers)
        let result = try await client.callTool("web_search_exa", arguments: [
            "query": query,
            "objective": "Verlässliche, fachlich korrekte Informationen zu: \(query)",
            "numResults": max(1, min(limit, 10)),
        ])
        if result.isError { throw MCPHTTPClient.MCPError.rpc(0, result.text) }
        return Self.parse(result.text)
    }

    /// Ergebnisse sind Klartext-Blöcke, getrennt durch `\n\n---\n\n`, mit Zeilen
    /// `Title:`, `URL:`, `Published:`, `Author:` und danach `Highlights:` + Text.
    static func parse(_ text: String) -> [SearchHit] {
        let chunks = text.components(separatedBy: "\n\n---\n\n")
        return chunks.enumerated().compactMap { index, chunk in
            var title = "", url = "", published: String?
            var body: [String] = []
            var inHighlights = false
            for line in chunk.components(separatedBy: "\n") {
                if inHighlights { body.append(line); continue }
                if line.hasPrefix("Title:") { title = value(line, "Title:") }
                else if line.hasPrefix("URL:") { url = value(line, "URL:") }
                else if line.hasPrefix("Published:") {
                    let v = value(line, "Published:")
                    published = (v.isEmpty || v == "N/A") ? nil : v
                } else if line.hasPrefix("Highlights:") || line.hasPrefix("Text:") {
                    inHighlights = true
                    let rest = line.hasPrefix("Highlights:") ? value(line, "Highlights:") : value(line, "Text:")
                    if !rest.isEmpty { body.append(rest) }
                }
            }
            guard !url.isEmpty else { return nil }
            let blocks = body.joined(separator: "\n")
                .components(separatedBy: "\n...\n")
                .flatMap { $0.components(separatedBy: "\n\n") }
                .map(ContentExtractor.clean)
                .filter { $0.count >= 20 }
            return SearchHit(source: .exa, title: title.isEmpty ? url : title, url: url,
                             snippet: String(blocks.first?.prefix(300) ?? ""), published: published,
                             blocks: blocks.isEmpty ? nil : ["# " + title] + blocks, rank: index)
        }
    }

    private static func value(_ line: String, _ prefix: String) -> String {
        String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}

/// Brave Search über die offizielle REST-API (`https://api.search.brave.com/res/v1/web/search`).
/// Standardmäßig aus; wird von der Pipeline nur als Fallback gefragt, wenn sowohl die Quelle `.brave`
/// aktiviert als auch ein nicht-leerer `apiKey` (Header `X-Subscription-Token`) hinterlegt ist.
nonisolated struct BraveSearchSource: SearchSource {
    var apiKey: String = ""
    var userAgent: String = SourceHTTP.apiUserAgent
    var id: ResearchSource { .brave }

    static let endpoint = "https://api.search.brave.com/res/v1/web/search"

    func search(_ query: String, limit: Int) async throws -> [SearchHit] {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return [] }
        guard let url = SourceHTTP.url(Self.endpoint, [
            "q": query,
            "count": String(max(1, min(limit, 20))),
            "extra_snippets": "true",
        ]) else { return [] }
        let json = try await SourceHTTP.json(url, userAgent: userAgent, headers: ["X-Subscription-Token": trimmedKey])
        return Self.parse(json)
    }

    static func parse(_ json: Any) -> [SearchHit] {
        guard let root = json as? [String: Any],
              let web = root["web"] as? [String: Any],
              let results = web["results"] as? [[String: Any]] else { return [] }
        return results.enumerated().compactMap { index, item in
            guard let rawURL = item["url"] as? String, !rawURL.isEmpty else { return nil }
            let rawTitle = (item["title"] as? String) ?? rawURL
            let title = stripHTML(rawTitle)
            let description = stripHTML((item["description"] as? String) ?? "")
            let published = (item["page_age"] as? String) ?? (item["age"] as? String)
            let extraSnippets = (item["extra_snippets"] as? [String] ?? [])
                .map(stripHTML)
                .filter { $0.count >= 20 }
            var blocks: [String]? = nil
            if !extraSnippets.isEmpty {
                var combined = ["# " + (title.isEmpty ? rawURL : title)]
                if description.count >= 20 { combined.append(description) }
                combined.append(contentsOf: extraSnippets)
                blocks = combined
            }
            return SearchHit(
                source: .brave,
                title: title.isEmpty ? rawURL : title,
                url: rawURL,
                snippet: String(description.prefix(300)),
                published: published,
                blocks: blocks,
                rank: index
            )
        }
    }

    private static func stripHTML(_ text: String) -> String {
        ContentExtractor.clean(text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
    }
}
