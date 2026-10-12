import Foundation

/// Minimaler MCP-Client für „Streamable HTTP“ (JSON-RPC 2.0 per POST). Bewusst ohne SDK:
/// Für Tool-Aufrufe genügt `tools/list` und `tools/call`. Antworten kommen je nach Server als
/// JSON oder als SSE (`event: message` / `data: {...}`) – beides wird gelesen.
///
/// Zustandslos: zuerst wird direkt `tools/call` versucht (z. B. Exa braucht keine Session).
/// Verlangt der Server eine Session (HTTP 400/404 oder JSON-RPC-Fehler), wird einmalig
/// `initialize` → `notifications/initialized` ausgeführt und der Aufruf mit Session wiederholt.
/// Grundlage für spätere, frei zuschaltbare MCP-Tools.
actor MCPHTTPClient {
    struct ToolResult: Equatable, Sendable {
        let text: String
        let isError: Bool
    }

    enum MCPError: LocalizedError, Equatable {
        case http(Int, String?)
        case rpc(Int, String)
        case invalidResponse
        case rateLimited

        var errorDescription: String? {
            switch self {
            case .http(let code, let message): return "MCP-Server antwortete mit HTTP \(code)" + (message.map { ": \($0)" } ?? "")
            case .rpc(_, let message):         return "MCP-Fehler: \(message)"
            case .invalidResponse:             return "Unerwartete Antwort des MCP-Servers."
            case .rateLimited:                 return "Kostenloses Kontingent des MCP-Servers erschöpft (HTTP 429)."
            }
        }
    }

    static let protocolVersion = "2025-06-18"

    let endpoint: URL
    private let headers: [String: String]
    private let timeout: TimeInterval
    private let session: URLSession
    private var sessionID: String?
    private var nextID = 1

    init(endpoint: URL, headers: [String: String] = [:], timeout: TimeInterval = 25, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.headers = headers
        self.timeout = timeout
        self.session = session
    }

    func listTools() async throws -> [[String: Any]] {
        let result = try await rpc("tools/list", params: [:])
        return (result["tools"] as? [[String: Any]]) ?? []
    }

    func callTool(_ name: String, arguments: [String: Any]) async throws -> ToolResult {
        let params: [String: Any] = ["name": name, "arguments": arguments]
        let result: [String: Any]
        do {
            result = try await rpc("tools/call", params: params)
        } catch MCPError.http(let code, _) where (code == 400 || code == 404) && sessionID == nil {
            try await initialize()
            result = try await rpc("tools/call", params: params)
        } catch MCPError.rpc(let code, _) where (code == -32600 || code == -32001) && sessionID == nil {
            try await initialize()
            result = try await rpc("tools/call", params: params)
        }
        let content = (result["content"] as? [[String: Any]]) ?? []
        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        return ToolResult(text: text, isError: result["isError"] as? Bool == true)
    }

    func initialize() async throws {
        _ = try await rpc("initialize", params: [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [:],
            "clientInfo": ["name": "LernAssist", "version": "2.0"],
        ])
        try await notify("notifications/initialized")
    }

    // MARK: Transport

    private func rpc(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        let body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let (data, response) = try await post(body)
        guard let http = response as? HTTPURLResponse else { throw MCPError.invalidResponse }
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !sid.isEmpty { sessionID = sid }
        if http.statusCode == 429 { throw MCPError.rateLimited }
        guard (200...299).contains(http.statusCode) else {
            throw MCPError.http(http.statusCode, LLMClient.serverMessage(fromBody: String(decoding: data.prefix(2_048), as: UTF8.self)))
        }
        let message = try Self.message(withID: id, in: data, contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "")
        if let error = message["error"] as? [String: Any] {
            throw MCPError.rpc(error["code"] as? Int ?? 0, error["message"] as? String ?? "Unbekannter Fehler")
        }
        guard let result = message["result"] as? [String: Any] else { throw MCPError.invalidResponse }
        return result
    }

    private func notify(_ method: String) async throws {
        let (_, response) = try await post(["jsonrpc": "2.0", "method": method])
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw MCPError.invalidResponse
        }
    }

    private func post(_ body: [String: Any]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await session.data(for: request)
    }

    /// Liest die JSON-RPC-Nachricht mit passender `id` aus JSON oder SSE.
    static func message(withID id: Int, in data: Data, contentType: String) throws -> [String: Any] {
        if contentType.lowercased().contains("text/event-stream") {
            let text = String(decoding: data, as: UTF8.self)
            var dataLines: [String] = []
            var candidates: [[String: Any]] = []
            func flushEvent() {
                guard !dataLines.isEmpty else { return }
                if let json = try? JSONSerialization.jsonObject(with: Data(dataLines.joined(separator: "\n").utf8)) as? [String: Any] {
                    candidates.append(json)
                }
                dataLines = []
            }
            for rawLine in text.components(separatedBy: "\n") {
                let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                if line.isEmpty { flushEvent(); continue }
                if line.hasPrefix("data:") {
                    var payload = String(line.dropFirst(5))
                    if payload.hasPrefix(" ") { payload.removeFirst() }
                    dataLines.append(payload)
                }
            }
            flushEvent()
            if let match = candidates.first(where: { ($0["id"] as? Int) == id }) ?? candidates.last { return match }
            throw MCPError.invalidResponse
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MCPError.invalidResponse }
        return json
    }
}
