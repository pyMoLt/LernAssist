import Foundation
import Darwin

/// Ergebnis eines Seitenabrufs.
nonisolated struct FetchedPage: Sendable {
    let url: URL
    let mimeType: String
    let textEncodingName: String?
    let data: Data
    let wasTruncated: Bool
}

nonisolated enum WebFetchError: LocalizedError, Equatable {
    case invalidURL
    case blockedAddress(String)
    case httpStatus(Int)
    /// Rate-Limit (429, oder 503 mit Retry-After): Wartezeit laut Server, falls angegeben.
    case rateLimited(Int, TimeInterval?)
    case unsupportedContent(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:                return "Ungültige oder nicht erlaubte URL (nur http/https)."
        case .blockedAddress(let host):  return "Adresse \(host) ist gesperrt (lokales/privates Netz)."
        case .httpStatus(let code):      return "Die Seite antwortete mit HTTP \(code)."
        case .rateLimited(let code, _):  return "Anfragegrenze erreicht (HTTP \(code))."
        case .unsupportedContent(let t): return "Inhaltstyp \(t) wird nicht gelesen."
        }
    }
}

/// Lädt öffentliche Webseiten für die Websuche – mit harten Grenzen:
/// - nur http/https, keine Zugangsdaten in der URL
/// - **SSRF-Sperre**: Hosts, die auf private, lokale, Link-Local- oder Tailscale-/CGNAT-Adressen
///   auflösen, werden abgelehnt – auch nach jeder Weiterleitung. Sonst könnte eine präparierte
///   Seite das Modell dazu bringen, LM Studio/oMLX, den Router oder Geräte im Tailnet abzufragen
///   (Audit 2026-10-12, Services H-3).
/// - keine Cookies, kein Cache, Größen- und Zeitlimit
nonisolated struct WebFetcher: Sendable {
    var timeout: TimeInterval = 15
    var maxBytes: Int = 10 * 1_024 * 1_024
    var maxRedirects: Int = 5
    var userAgent: String = WebFetcher.userAgent

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15 LernAssist"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    func fetch(_ url: URL, accept: String = "text/html,application/xhtml+xml,application/pdf,text/plain;q=0.9,*/*;q=0.5", headers: [String: String] = [:]) async throws -> FetchedPage {
        try await Self.validate(url)
        // Höflicher Abstand pro Host (Fach-APIs, Volltexte) – siehe HostPacing.
        if let host = url.host { try await HostPacing.shared.waitTurn(host: host) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("de-DE,de;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let guardDelegate = RedirectGuard(maxRedirects: maxRedirects)
        // Download in eine temporäre Datei statt Byte-für-Byte über AsyncBytes: Letzteres brauchte
        // für ein 1,3-MB-PDF über 10 s und lief in die Zeitgrenze (abgeschnittenes PDF → „leere
        // Seite“, Live-Test 13.10.2026). Das Gesamtlimit sichert ein Task-Timeout ab.
        let (fileURL, response) = try await withThrowingTaskGroup(of: (URL, URLResponse).self) { group in
            group.addTask { try await Self.session.download(for: request, delegate: guardDelegate) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw URLError(.timedOut)
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        defer { try? FileManager.default.removeItem(at: fileURL) }
        if let error = guardDelegate.error { throw error }
        guard let http = response as? HTTPURLResponse else { throw WebFetchError.invalidURL }
        guard (200...299).contains(http.statusCode) else {
            // Rate-Limit: 429 immer, 503 nur mit Retry-After (sonst ist es ein Ausfall des Dienstes).
            // Der Host wird pausiert – Folgeanfragen werden dann sofort übersprungen statt zu warten.
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            if http.statusCode == 429 || (http.statusCode == 503 && retryAfter != nil) {
                if let host = url.host { await HostPacing.shared.pause(host: host, seconds: retryAfter ?? 60) }
                throw WebFetchError.rateLimited(http.statusCode, retryAfter)
            }
            throw WebFetchError.httpStatus(http.statusCode)
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        let truncated = size > maxBytes
        let data: Data
        if truncated {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            data = try handle.read(upToCount: maxBytes) ?? Data()
        } else {
            data = try Data(contentsOf: fileURL)
        }
        return FetchedPage(url: http.url ?? url,
                           mimeType: (http.mimeType ?? "application/octet-stream").lowercased(),
                           textEncodingName: http.textEncodingName,
                           data: data, wasTruncated: truncated)
    }

    // MARK: SSRF-Prüfung

    static func validate(_ url: URL) async throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil else {
            throw WebFetchError.invalidURL
        }
        if isBlockedHostname(host) { throw WebFetchError.blockedAddress(host) }
        if let literal = IPAddress(host), literal.isPrivate { throw WebFetchError.blockedAddress(host) }
        let addresses = await resolve(host)
        if addresses.contains(where: \.isPrivate) { throw WebFetchError.blockedAddress(host) }
    }

    static func isBlockedHostname(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
            || host.hasSuffix(".internal") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa")
            || host.hasSuffix(".ts.net") || !host.contains(".") && IPAddress(host) == nil
    }

    private static func resolve(_ host: String) async -> [IPAddress] {
        await Task.detached(priority: .userInitiated) { () -> [IPAddress] in
            var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                                 ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
            defer { freeaddrinfo(first) }
            var addresses: [IPAddress] = []
            var pointer: UnsafeMutablePointer<addrinfo>? = first
            while let info = pointer?.pointee {
                if let address = IPAddress(sockaddr: info.ai_addr) { addresses.append(address) }
                pointer = info.ai_next
            }
            return addresses
        }.value
    }
}

/// Prüft jede Weiterleitung erneut (Ziel könnte ein internes Netz sein).
nonisolated final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let maxRedirects: Int
    private let lock = NSLock()
    private var count = 0
    private var _error: Error?

    var error: Error? { lock.withLock { _error } }

    init(maxRedirects: Int) { self.maxRedirects = maxRedirects }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let current = lock.withLock { count += 1; return count }
        guard current <= maxRedirects, let url = request.url else { completionHandler(nil); return }
        Task {
            do {
                try await WebFetcher.validate(url)
                completionHandler(request)
            } catch {
                self.lock.withLock { self._error = error }
                completionHandler(nil)
            }
        }
    }
}

/// Minimale IP-Adress-Darstellung für die Sperrprüfung.
nonisolated struct IPAddress: Equatable, Sendable {
    let bytes: [UInt8]

    init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, trimmed, &v4) == 1 {
            bytes = withUnsafeBytes(of: v4) { Array($0) }
        } else if inet_pton(AF_INET6, trimmed, &v6) == 1 {
            bytes = withUnsafeBytes(of: v6) { Array($0) }
        } else {
            return nil
        }
    }

    init?(sockaddr pointer: UnsafeMutablePointer<sockaddr>?) {
        guard let pointer else { return nil }
        switch Int32(pointer.pointee.sa_family) {
        case AF_INET:
            bytes = pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
        case AF_INET6:
            bytes = pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
        default:
            return nil
        }
    }

    var isPrivate: Bool {
        if bytes.count == 4 { return Self.isPrivateV4(bytes) }
        guard bytes.count == 16 else { return true }
        if bytes.allSatisfy({ $0 == 0 }) { return true }                                  // ::
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }        // ::1
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            return Self.isPrivateV4(Array(bytes[12..<16]))                                // ::ffff:a.b.c.d
        }
        if bytes[0] & 0xfe == 0xfc { return true }                                        // fc00::/7 (ULA, Tailscale)
        if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return true }                    // fe80::/10
        if bytes[0] == 0xff { return true }                                               // Multicast
        return false
    }

    private static func isPrivateV4(_ b: [UInt8]) -> Bool {
        switch b[0] {
        case 0, 10, 127: return true
        case 100: return b[1] & 0xc0 == 64          // 100.64.0.0/10 – CGNAT, Tailscale
        case 169: return b[1] == 254                // Link-Local
        case 172: return b[1] & 0xf0 == 16          // 172.16.0.0/12
        case 192: return b[1] == 168 || (b[1] == 0 && b[2] == 0)
        case 198: return b[1] == 18 || b[1] == 19   // Benchmark-Netz
        default: return b[0] >= 224                 // Multicast/reserviert
        }
    }
}
