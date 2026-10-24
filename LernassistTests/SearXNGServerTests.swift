import XCTest
@testable import Lernassist

/// SearXNG-Katalog (Version 4.0): Übernahme der alten Adresse, Anmelde-Header.
final class SearXNGServerTests: XCTestCase {

    func testOldSingleURLBecomesCatalogEntry() {
        var stored = PersistedSettings.defaults
        stored.searxngURL = "http://100.64.0.5:8082"
        stored.searxngServers = []
        let catalog = ChatViewModel.searxngCatalog(from: stored)
        XCTAssertEqual(catalog.servers.count, 1)
        XCTAssertEqual(catalog.servers.first?.url, "http://100.64.0.5:8082")
        XCTAssertEqual(catalog.servers.first?.location, .remote)
        XCTAssertEqual(catalog.activeID, catalog.servers.first?.id)

        stored.searxngURL = "http://127.0.0.1:8082"
        XCTAssertEqual(ChatViewModel.searxngCatalog(from: stored).servers.first?.location, .local)
    }

    func testActiveServerIsKept() {
        var stored = PersistedSettings.defaults
        let local = SearXNGServer(name: "Lokal", url: "http://127.0.0.1:8082", location: .local)
        let caddy = SearXNGServer(name: "Caddy", url: "https://search.example.org", location: .remote, auth: .bearer)
        stored.searxngServers = [local, caddy]
        stored.activeSearXNGServerID = caddy.id
        let catalog = ChatViewModel.searxngCatalog(from: stored)
        XCTAssertEqual(catalog.activeID, caddy.id)
        let roundTrip = try? JSONDecoder().decode(PersistedSettings.self, from: JSONEncoder().encode(stored))
        XCTAssertEqual(roundTrip?.searxngServers, [local, caddy])
        XCTAssertEqual(roundTrip?.activeSearXNGServerID, caddy.id)
    }

    func testAuthHeaders() {
        var server = SearXNGServer(name: "Caddy", url: "https://search.example.org", location: .remote, auth: .bearer)
        XCTAssertEqual(server.authHeaders(secret: " abc "), ["Authorization": "Bearer abc"])
        XCTAssertEqual(server.authHeaders(secret: ""), [:], "Ohne Geheimnis keine Header")

        server.auth = .basic
        server.username = "nutzer"
        XCTAssertEqual(server.authHeaders(secret: "pw"), ["Authorization": "Basic " + Data("nutzer:pw".utf8).base64EncodedString()])

        server.auth = .header
        server.headerName = "X-API-Key"
        XCTAssertEqual(server.authHeaders(secret: "k"), ["X-API-Key": "k"])

        server.auth = .none
        XCTAssertEqual(server.authHeaders(secret: "k"), [:])
    }
}
