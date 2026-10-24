import Foundation

/// Wie eine Quelle bei einer Suche abgeschnitten hat – für den Tool-Schritt im Chat.
nonisolated struct ResearchSourceStatus: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        /// `unreachable`: keine Verbindung zum Server (Adresse falsch, Gerät aus, keine Route).
        /// `skipped`: Nachzügler nach frühem Abschluss – zählt nicht als Ausfall.
        case ok, empty, failed, rateLimited, paused, timeout, unreachable, skipped
    }
    var source: ResearchSource
    var state: State
    /// Dauer der Anfrage (nil = nicht gefragt).
    var seconds: Double?
    var hits: Int = 0
    /// Bei Pause: Minuten bis zur nächsten Anfrage.
    var minutesLeft: Int?
}

/// Merkt sich, welche Quellen gerade nicht gefragt werden (Version 4.0):
/// - Rate-Limit (429, 503 mit Retry-After, Stack-Exchange-`backoff`, „quota/rate limit“ in der Antwort)
///   → Quelle sofort für N Minuten pausieren.
/// - Ausfall (5xx ohne Retry-After, 403, Timeout, keine Verbindung) → diese Suche überspringen;
///   beim zweiten Ausfall hintereinander ebenfalls N Minuten pausieren.
/// - 0 Treffer sind kein Fehler.
/// Nur im RAM: Nach einem Neustart wird jede Quelle wieder gefragt.
actor SourceHealth {
    static let shared = SourceHealth()

    enum Failure: Equatable, Sendable {
        case rateLimit
        case outage
    }

    struct Pause: Equatable, Sendable {
        var until: Date
        var reason: Failure
    }

    private var paused: [ResearchSource: Pause] = [:]
    private var consecutiveFailures: [ResearchSource: Int] = [:]

    /// Aktive Pause einer Quelle (abgelaufene werden entfernt).
    func pause(for source: ResearchSource, now: Date = Date()) -> Pause? {
        guard let pause = paused[source] else { return nil }
        if pause.until <= now {
            paused[source] = nil
            return nil
        }
        return pause
    }

    func allPauses(now: Date = Date()) -> [ResearchSource: Pause] {
        paused = paused.filter { $0.value.until > now }
        return paused
    }

    func recordSuccess(_ source: ResearchSource) {
        consecutiveFailures[source] = 0
    }

    /// Fehler einer Quelle verbuchen. Liefert true, wenn die Quelle jetzt pausiert ist.
    @discardableResult
    func recordFailure(_ source: ResearchSource, kind: Failure, pauseMinutes: Double, now: Date = Date()) -> Bool {
        let minutes = max(0.5, pauseMinutes)
        switch kind {
        case .rateLimit:
            consecutiveFailures[source] = 0
            paused[source] = Pause(until: now.addingTimeInterval(minutes * 60), reason: .rateLimit)
            return true
        case .outage:
            let count = (consecutiveFailures[source] ?? 0) + 1
            consecutiveFailures[source] = count
            guard count >= 2 else { return false }
            consecutiveFailures[source] = 0
            paused[source] = Pause(until: now.addingTimeInterval(minutes * 60), reason: .outage)
            return true
        }
    }

    /// Pause von Hand aufheben (Einstellungen → Recherche).
    func resume(_ source: ResearchSource) {
        paused[source] = nil
        consecutiveFailures[source] = 0
    }

    func resumeAll() {
        paused.removeAll()
        consecutiveFailures.removeAll()
    }

    /// Keine Verbindung zum Server (statt einer Fehlerantwort) – für die Meldung „nicht erreichbar“.
    nonisolated static func isConnectionFailure(_ error: Error) -> Bool {
        let codes: Set<URLError.Code> = [.timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                                         .notConnectedToInternet, .networkConnectionLost, .secureConnectionFailed]
        if let url = error as? URLError { return codes.contains(url.code) }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && codes.contains(URLError.Code(rawValue: ns.code))
    }

    /// Fehlerart. nil = kein echter Fehler (z. B. „keine Ergebnisse“).
    nonisolated static func classify(_ error: Error) -> Failure? {
        if let search = error as? SearchService.SearchError {
            switch search {
            case .noResults: return nil
            case .rateLimited: return .rateLimit
            case .httpError(let code): return code == 429 ? .rateLimit : .outage
            default: return .outage
            }
        }
        if let fetch = error as? WebFetchError {
            switch fetch {
            case .rateLimited: return .rateLimit
            case .httpStatus(let code): return code == 429 ? .rateLimit : .outage
            default: return .outage
            }
        }
        let text = (error.localizedDescription + " " + String(describing: error)).lowercased()
        let rateWords = ["rate limit", "rate-limit", "ratelimit", "too many requests", "quota", "throttl", "backoff"]
        if rateWords.contains(where: text.contains) { return .rateLimit }
        return .outage
    }
}
