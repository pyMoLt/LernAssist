import Foundation

/// Ergebnis eines Verbindungstests – mit einer Meldung, die sagt, WAS zu tun ist.
nonisolated struct ConnectionDiagnosis: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case ok
        /// Server erreichbar, lädt aber noch (oMLX `/health` → 503 "loading").
        case loading
        case unauthorized
        case unreachable
        case failed
    }

    let status: Status
    let message: String
    var modelCount: Int = 0

    var isOK: Bool { status == .ok || status == .loading }
}

/// Verbindungstest je Anbieter. Für oMLX zuerst `/health` (ohne Key), dann `/v1/models`
/// (mit Key) – so lassen sich „Server aus“, „Key fehlt/falsch“ und „lädt noch“ unterscheiden.
nonisolated enum EndpointDiagnostics {

    static func diagnose(_ profile: EndpointProfile, session: URLSession = .shared) async -> ConnectionDiagnosis {
        let base = EndpointManager.normalizedBase(profile.baseURL)
        let timeout: TimeInterval = profile.isRemote ? 10 : 5

        if profile.provider == .omlx, let healthURL = OMLXAdapter().healthURL(base: base) {
            do {
                let (_, response) = try await session.data(for: URLRequest(url: healthURL, timeoutInterval: timeout))
                if (response as? HTTPURLResponse)?.statusCode == 503 {
                    return ConnectionDiagnosis(status: .loading, message: "oMLX läuft, lädt aber noch Modelle.")
                }
            } catch {
                return unreachable(profile, error: error)
            }
        }

        do {
            let models = try await EndpointManager.fetchProviderModels(for: profile)
            let hasModel = profile.model.isEmpty || models.isEmpty || models.contains { $0.id == profile.model }
            let message = hasModel
                ? "Verbunden – \(models.count) Modell(e) verfügbar."
                : "Verbunden, aber das Modell „\(profile.model)“ ist auf dem Server nicht bekannt."
            return ConnectionDiagnosis(status: hasModel ? .ok : .failed, message: message, modelCount: models.count)
        } catch EndpointManager.EndpointError.httpError(let code, let serverMessage) where code == 401 || code == 403 {
            let hint = profile.apiKey.isEmpty
                ? "API-Key fehlt. Lauscht der Server nicht nur lokal (z. B. auf der Tailscale-IP), ist ein Key Pflicht."
                : "API-Key wurde abgelehnt."
            return ConnectionDiagnosis(status: .unauthorized, message: hint + (serverMessage.map { " (\($0))" } ?? ""))
        } catch EndpointManager.EndpointError.httpError(let code, let serverMessage) {
            return ConnectionDiagnosis(status: .failed, message: "HTTP \(code)" + (serverMessage.map { ": \($0)" } ?? ""))
        } catch {
            return unreachable(profile, error: error)
        }
    }

    private static func unreachable(_ profile: EndpointProfile, error: Error) -> ConnectionDiagnosis {
        let hint = profile.isRemote
            ? "Nicht erreichbar. Läuft der Server auf dem anderen Mac, ist Tailscale verbunden und der Mac wach?"
            : "Nicht erreichbar. Läuft der Server auf diesem Mac?"
        return ConnectionDiagnosis(status: .unreachable, message: hint + " (\(error.localizedDescription))")
    }

    /// Modellstatus von oMLX (Typ/Vision, geladen, Kontextfenster). Leeres Ergebnis bei Fehlern.
    static func omlxStatus(_ profile: EndpointProfile, session: URLSession = .shared) async -> [ProviderModel] {
        let adapter = OMLXAdapter()
        guard let url = adapter.statusURL(base: EndpointManager.normalizedBase(profile.baseURL)) else { return [] }
        var request = URLRequest(url: url, timeoutInterval: profile.isRemote ? 15 : 8)
        EndpointManager.authHeaders(for: profile).forEach { request.setValue($1, forHTTPHeaderField: $0) }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return adapter.parseStatus(json)
    }
}
