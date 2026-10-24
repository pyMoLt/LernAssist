import Foundation

// MARK: - SearXNG-Katalog (Version 4.0)

/// Ein Such-Server (SearXNG) im Katalog der Recherche – wie die Endpunkt-Profile: mehrere Einträge,
/// einer ist aktiv. Geheimnisse (Token, Passwort) liegen nur im Schlüsselbund, nie in `settings.json`.
nonisolated struct SearXNGServer: Codable, Equatable, Identifiable, Sendable {
    enum Location: String, Codable, CaseIterable, Sendable {
        /// Läuft auf diesem Mac.
        case local
        /// Anderer Rechner (Tailscale, Reverse-Proxy …).
        case remote
    }

    enum Auth: String, Codable, CaseIterable, Sendable {
        case none
        /// `Authorization: Bearer <Token>` – z. B. hinter Caddy.
        case bearer
        /// Benutzer und Passwort (HTTP Basic).
        case basic
        /// Eigener Header (Name frei, Wert aus dem Schlüsselbund).
        case header
    }

    var id = UUID()
    var name: String
    var url: String
    var location: Location
    var auth: Auth = .none
    var username: String = ""
    var headerName: String = ""

    init(name: String, url: String, location: Location, auth: Auth = .none) {
        self.name = name
        self.url = url
        self.location = location
        self.auth = auth
    }

    private enum CodingKeys: String, CodingKey { case id, name, url, location, auth, username, headerName }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "SearXNG"
        url = (try? c.decode(String.self, forKey: .url)) ?? ""
        location = (try? c.decode(Location.self, forKey: .location)) ?? .local
        auth = (try? c.decode(Auth.self, forKey: .auth)) ?? .none
        username = (try? c.decode(String.self, forKey: .username)) ?? ""
        headerName = (try? c.decode(String.self, forKey: .headerName)) ?? ""
    }

    /// Schlüsselbund-Eintrag für Token bzw. Passwort dieses Servers.
    var keychainAccount: String { "searxng-\(id.uuidString)" }

    /// Lokal, wenn die Adresse auf diesen Mac zeigt.
    static func guessLocation(for url: String) -> Location {
        let lower = url.lowercased()
        return ["127.0.0.1", "localhost", "[::1]"].contains(where: lower.contains) ? .local : .remote
    }

    /// Eintrag aus der früheren einzelnen SearXNG-Adresse.
    static func migrated(from url: String) -> SearXNGServer {
        let location = guessLocation(for: url)
        return SearXNGServer(name: location == .local ? "Lokal" : "Remote", url: url, location: location)
    }

    /// HTTP-Header für die Anmeldung. Ohne Geheimnis: keine Header (der Server meldet dann 401).
    func authHeaders(secret: String) -> [String: String] {
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { return [:] }
        switch auth {
        case .none:
            return [:]
        case .bearer:
            return ["Authorization": "Bearer \(secret)"]
        case .basic:
            let pair = "\(username):\(secret)"
            return ["Authorization": "Basic \(Data(pair.utf8).base64EncodedString())"]
        case .header:
            let name = headerName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? [:] : [name: secret]
        }
    }
}
