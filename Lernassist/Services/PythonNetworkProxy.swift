import Foundation
import Network

/// Internet für die Python-Sandbox. Python darf nur zu diesem Proxy auf dem eigenen Mac
/// (Sandbox-Regel), der Proxy entscheidet pro Verbindung:
/// - nur HTTPS (CONNECT auf Port 443), keine lokalen/privaten/Tailscale-Adressen,
/// - Domain auf der Freigabeliste oder vom Nutzer bestätigt (Einmal / Immer / Ablehnen),
/// - höchstens N Verbindungen pro Lauf und M MB pro Verbindung.
/// Bei HTTPS sieht der Proxy nur die Domain – Dateityp und Größe prüft zusätzlich der Vorspann
/// in Python (`Content-Type`), gefährliche Dateien entfernt die Prüfung nach dem Lauf.
/// Pro Python-Lauf läuft ein eigener Proxy (eigene Zähler), danach wird er beendet.
nonisolated final class PythonNetworkProxy: @unchecked Sendable {
    struct Policy: Sendable {
        var maxConnections: Int
        var maxBytesPerConnection: Int
    }

    /// Fragt nach der Freigabe für eine Domain (Freigabeliste oder Dialog).
    typealias PermissionHandler = @Sendable (String) async -> Bool

    private let policy: Policy
    private let permission: PermissionHandler
    private let queue = DispatchQueue(label: "lernassist.python-proxy")
    private var listener: NWListener?
    private let lock = NSLock()
    private var connectionsUsed = 0
    private var waited: TimeInterval = 0
    /// Offene Freigabe-Dialoge und seit wann der älteste offen ist (die Uhr steht sofort still).
    private var pendingDialogs = 0
    private var pendingSince: Date?
    private var events: [String] = []
    private var active: [ObjectIdentifier: NWConnection] = [:]

    init(policy: Policy, permission: @escaping PermissionHandler) {
        self.policy = policy
        self.permission = permission
    }

    /// Zeit, die Python auf Freigabe-Dialoge gewartet hat (zählt nicht gegen das Zeitlimit).
    var waitingTime: TimeInterval {
        lock.withLock { waited + (pendingSince.map { Date().timeIntervalSince($0) } ?? 0) }
    }
    /// Zahl der aufgebauten Verbindungen in diesem Lauf.
    var usedConnections: Int { lock.lock(); defer { lock.unlock() }; return connectionsUsed }
    /// Kurzprotokoll für das Tool-Ergebnis („ourworldindata.org: erlaubt“).
    var eventLog: [String] { lock.lock(); defer { lock.unlock() }; return events }

    private func record(_ event: String) {
        lock.withLock { events.append(event) }
    }

    // MARK: Start/Stop

    /// Startet auf 127.0.0.1 mit freiem Port und liefert den Port.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    guard once.claim() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        let open = Array(active.values)
        active.removeAll()
        lock.unlock()
        open.forEach { $0.cancel() }
    }

    private func track(_ connection: NWConnection) {
        lock.lock(); active[ObjectIdentifier(connection)] = connection; lock.unlock()
    }

    // MARK: Verbindung von Python

    private func accept(_ client: NWConnection) {
        track(client)
        client.start(queue: queue)
        readHeader(client, buffer: Data())
    }

    /// Liest die Anfrage bis zur Leerzeile (höchstens 16 KB).
    private func readHeader(_ client: NWConnection, buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let rest = buffer[end.upperBound...]
                Task { await self.handle(client, header: header, leftover: Data(rest)) }
            } else if error != nil || isComplete || buffer.count > 16_384 {
                client.cancel()
            } else {
                self.readHeader(client, buffer: buffer)
            }
        }
    }

    private func reject(_ client: NWConnection, _ reason: String) {
        // Die Begründung steht in der Statuszeile – requests/urllib zeigen sie in der Fehlermeldung.
        let response = "HTTP/1.1 403 \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        client.send(content: Data(response.utf8), completion: .contentProcessed { _ in client.cancel() })
    }

    private func handle(_ client: NWConnection, header: String, leftover: Data) async {
        let requestLine = header.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0].uppercased() == "CONNECT" else {
            record("abgelehnt: nur HTTPS erlaubt")
            reject(client, "LernAssist: only https is allowed")
            return
        }
        let target = String(parts[1])
        guard let colon = target.lastIndex(of: ":"), target[target.index(after: colon)...] == "443" else {
            reject(client, "LernAssist: only port 443 is allowed")
            return
        }
        let host = target[..<colon].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        let overLimit = lock.withLock {
            let over = connectionsUsed >= policy.maxConnections
            if !over { connectionsUsed += 1 }
            return over
        }
        guard !overLimit else {
            record("\(host): abgelehnt (Limit von \(policy.maxConnections) Downloads pro Lauf)")
            reject(client, "LernAssist: download limit per run reached")
            return
        }

        // Keine lokalen, privaten oder Tailscale-Adressen (gleiche Prüfung wie die Websuche).
        guard let url = URL(string: "https://\(host)/"), (try? await WebFetcher.validate(url)) != nil else {
            record("\(host): gesperrt (lokale oder private Adresse)")
            reject(client, "LernAssist: local or private addresses are blocked")
            return
        }

        lock.withLock {
            if pendingDialogs == 0 { pendingSince = Date() }
            pendingDialogs += 1
        }
        let allowed = await permission(host)
        lock.withLock {
            pendingDialogs -= 1
            if pendingDialogs == 0, let since = pendingSince {
                waited += Date().timeIntervalSince(since)
                pendingSince = nil
            }
        }
        guard allowed else {
            record("\(host): vom Nutzer abgelehnt")
            reject(client, "LernAssist: domain denied by user")
            return
        }
        record("\(host): erlaubt")
        connectRemote(client: client, host: host, leftover: leftover)
    }

    // MARK: Tunnel

    private func connectRemote(client: NWConnection, host: String, leftover: Data) {
        let remote = NWConnection(host: NWEndpoint.Host(host), port: 443, using: .tcp)
        track(remote)
        remote.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let established = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
                client.send(content: established, completion: .contentProcessed { _ in
                    if !leftover.isEmpty { remote.send(content: leftover, completion: .contentProcessed { _ in }) }
                    self.pipe(from: client, to: remote, counted: false, total: 0, host: host)
                    self.pipe(from: remote, to: client, counted: true, total: 0, host: host)
                })
            case .failed, .cancelled:
                client.cancel()
            case .waiting:
                self.reject(client, "LernAssist: host not reachable")
                remote.cancel()
            default:
                break
            }
        }
        remote.start(queue: queue)
    }

    /// Leitet Daten weiter; die Richtung Internet → Python zählt gegen das Größenlimit.
    private func pipe(from source: NWConnection, to destination: NWConnection, counted: Bool, total: Int, host: String) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var total = total
            if let data, !data.isEmpty {
                total += counted ? data.count : 0
                if counted, total > self.policy.maxBytesPerConnection {
                    self.record("\(host): abgebrochen (größer als \(self.policy.maxBytesPerConnection / 1_048_576) MB)")
                    source.cancel()
                    destination.cancel()
                    return
                }
                destination.send(content: data, completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
                return
            }
            self.pipe(from: source, to: destination, counted: counted, total: total, host: host)
        }
    }
}

/// Einmal-Schalter für Fortsetzungen, die von mehreren Zustandswechseln ausgelöst werden könnten.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

