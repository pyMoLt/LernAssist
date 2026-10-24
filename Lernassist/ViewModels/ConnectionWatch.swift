import Foundation
import AppKit
import Combine
import UserNotifications

/// Ein Verbindungsproblem, das der Wächter gefunden hat.
struct ConnectionIssue: Identifiable, Equatable, Sendable {
    /// Stabil pro Ziel („endpoint-<id>“, „searxng-<id>“), damit Wegklicken an diesem Ziel hängt.
    let id: String
    let title: String
    let detail: String
    /// Reiter der Einstellungen, in dem sich das Problem beheben lässt.
    let settingsTab: String
}

/// Verbindungswächter (Version 4.0): prüft etwa eine Minute nach dem Start und danach im Leerlauf
/// alle fünf Minuten das aktive Profil, das Fallback-Profil und den aktiven Such-Server.
/// Probleme erscheinen als wegklickbarer Hinweis im Chat; ist die App im Hintergrund, zusätzlich
/// als Mitteilung von macOS. Weggeklickt bleibt ein Hinweis weg, bis das Ziel einmal wieder
/// funktioniert hat und erneut ausfällt. Ein Fehler wird erst nach einer zweiten Prüfung gemeldet,
/// damit kurze Aussetzer keinen Hinweis auslösen.
@MainActor
final class ConnectionWatch: ObservableObject {
    static let shared = ConnectionWatch()

    @Published private(set) var issues: [ConnectionIssue] = []

    static let firstCheckDelay: TimeInterval = 60
    static let interval: TimeInterval = 300
    static let confirmDelay: TimeInterval = 15

    private var loop: Task<Void, Never>?
    private var dismissed: Set<String> = []
    private var notified: Set<String> = []
    private weak var viewModel: ChatViewModel?

    func start(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.firstCheckDelay * 1_000_000_000))
            while !Task.isCancelled {
                await self?.checkIfIdle()
                try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
            }
        }
    }

    func dismiss(_ issue: ConnectionIssue) {
        dismissed.insert(issue.id)
        issues.removeAll { $0.id == issue.id }
    }

    /// Prüft sofort (z. B. nach einer Änderung in den Einstellungen) – ohne Bestätigungsrunde.
    func checkNow() async {
        guard let viewModel else { return }
        apply(await Self.problems(for: viewModel))
    }

    private func checkIfIdle() async {
        guard let viewModel, viewModel.connectionWatchEnabled else {
            issues = []
            return
        }
        // Nicht während einer Antwort: Der Server ist dann beschäftigt, und Prüfen kostet nur Zeit.
        guard !viewModel.isStreaming else { return }
        let first = await Self.problems(for: viewModel)
        guard !first.isEmpty else {
            apply([])
            return
        }
        try? await Task.sleep(nanoseconds: UInt64(Self.confirmDelay * 1_000_000_000))
        let second = await Self.problems(for: viewModel)
        // Nur melden, was bei beiden Prüfungen fehlschlug.
        let confirmed = second.filter { issue in first.contains { $0.id == issue.id } }
        apply(confirmed)
    }

    private func apply(_ found: [ConnectionIssue]) {
        let ids = Set(found.map(\.id))
        // Wieder funktionierende Ziele dürfen beim nächsten Ausfall erneut melden.
        dismissed = dismissed.intersection(ids)
        notified = notified.intersection(ids)
        issues = found.filter { !dismissed.contains($0.id) }
        postSystemNotices(for: issues)
    }

    // MARK: Prüfen

    private static func problems(for viewModel: ChatViewModel) async -> [ConnectionIssue] {
        var targets: [EndpointProfile] = []
        if let active = viewModel.activeProfile { targets.append(active) }
        if let fallback = viewModel.profiles.first(where: { $0.id == viewModel.fallbackProfileID }),
           !targets.contains(where: { $0.id == fallback.id }) {
            targets.append(fallback)
        }
        let server = viewModel.searchEnabled && viewModel.research.enabledSources.contains(.searxng)
            ? viewModel.activeSearXNGServer : nil
        let headers = viewModel.searxngHeaders(for: server)
        let fallbackID = viewModel.fallbackProfileID

        return await withTaskGroup(of: ConnectionIssue?.self) { group in
            for profile in targets {
                group.addTask {
                    let diagnosis = await EndpointDiagnostics.diagnose(profile)
                    switch diagnosis.status {
                    case .ok, .loading: return nil
                    default:
                        let role = profile.id == fallbackID ? L("Fallback-Endpunkt") : L("Endpunkt")
                        return ConnectionIssue(id: "endpoint-\(profile.id.uuidString)",
                                               title: L("\(role) „\(profile.name)“ antwortet nicht"),
                                               detail: diagnosis.message,
                                               settingsTab: "Endpoints")
                    }
                }
            }
            if let server, !server.url.trimmingCharacters(in: .whitespaces).isEmpty {
                group.addTask {
                    let result = await viewModel.testSearxngConnection(baseURL: server.url, headers: headers)
                    if case .ok = result { return nil }
                    return ConnectionIssue(id: "searxng-\(server.id.uuidString)",
                                           title: L("Such-Server „\(server.name)“ nicht erreichbar"),
                                           detail: result.diagnostic.replacingOccurrences(of: "✗ ", with: ""),
                                           settingsTab: "Search")
                }
            }
            var found: [ConnectionIssue] = []
            for await issue in group { if let issue { found.append(issue) } }
            return found.sorted { $0.id < $1.id }
        }
    }

    // MARK: Mitteilungen von macOS

    private func postSystemNotices(for issues: [ConnectionIssue]) {
        guard let viewModel, viewModel.connectionWatchSystemNotices, !NSApp.isActive else { return }
        let fresh = issues.filter { !notified.contains($0.id) }
        guard !fresh.isEmpty else { return }
        notified.formUnion(fresh.map(\.id))
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            for issue in fresh {
                let content = UNMutableNotificationContent()
                content.title = issue.title
                content.body = issue.detail
                center.add(UNNotificationRequest(identifier: "connection-\(issue.id)", content: content, trigger: nil))
            }
        }
    }
}
