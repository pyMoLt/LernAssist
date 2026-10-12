import Foundation

/// Sortiert Texte nach Relevanz zu einer Frage. Gibt Scores (0…1) in Eingabereihenfolge zurück.
nonisolated protocol Reranker: Sendable {
    func scores(query: String, documents: [String]) async throws -> [Double]
}

/// Reranker über oMLX `POST /v1/rerank` (Cohere/Jina-Format), z. B. Qwen3-Reranker-0.6B.
nonisolated struct OMLXReranker: Reranker {
    let profile: EndpointProfile
    let model: String
    var timeout: TimeInterval = 8
    var session: URLSession = .shared

    func scores(query: String, documents: [String]) async throws -> [Double] {
        guard !documents.isEmpty else { return [] }
        guard let url = OMLXAdapter().rerankURL(base: EndpointManager.normalizedBase(profile.baseURL)) else {
            throw EndpointManager.EndpointError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        EndpointManager.authHeaders(for: profile).forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "query": query,
            "documents": documents,
            "top_n": documents.count,
            "return_documents": false,
        ] as [String: Any])

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw EndpointManager.EndpointError.httpError(
                http.statusCode, message: LLMClient.serverMessage(fromBody: String(decoding: data.prefix(2_048), as: UTF8.self)))
        }
        return try Self.parse(data, count: documents.count)
    }

    static func parse(_ data: Data, count: Int) throws -> [Double] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = (json["results"] as? [[String: Any]]) ?? (json["data"] as? [[String: Any]]) else {
            throw EndpointManager.EndpointError.parseError
        }
        var scores = Array(repeating: 0.0, count: count)
        for result in results {
            guard let index = result["index"] as? Int, scores.indices.contains(index) else { continue }
            scores[index] = (result["relevance_score"] as? Double) ?? (result["score"] as? Double) ?? 0
        }
        return scores
    }
}
