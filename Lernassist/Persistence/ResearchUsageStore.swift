import Foundation
import Combine

/// Zählt die Suchen pro Recherche-Quelle (heute, dieser Monat) und merkt sich den letzten Fehler.
/// Die App sieht nur, was sie selbst geschickt hat – das Restkontingent einer Quelle (z. B. der
/// kostenlosen Exa-Stufe) lässt sich nicht abfragen. Ablage: `research-usage.json`.
@MainActor
final class ResearchUsageStore: ObservableObject {
    static let shared = ResearchUsageStore()

    struct Entry: Codable, Equatable {
        var day = ""
        var dayCount = 0
        var month = ""
        var monthCount = 0
        var lastUsedAt: Date?
        var lastError: String?
        var lastErrorAt: Date?
    }

    @Published private(set) var entries: [String: Entry] = [:]

    private static var fileURL: URL { AppStorageLocation.root.appendingPathComponent("research-usage.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    static func dayKey(_ date: Date = Date()) -> String { String(ISO8601DateFormatter.localDay.string(from: date).prefix(10)) }
    static func monthKey(_ date: Date = Date()) -> String { String(dayKey(date).prefix(7)) }

    func record(_ source: ResearchSource, error: String? = nil, now: Date = Date()) {
        var entry = entries[source.rawValue] ?? Entry()
        let day = Self.dayKey(now), month = Self.monthKey(now)
        if entry.day != day { entry.day = day; entry.dayCount = 0 }
        if entry.month != month { entry.month = month; entry.monthCount = 0 }
        entry.dayCount += 1
        entry.monthCount += 1
        entry.lastUsedAt = now
        if let error {
            entry.lastError = String(error.prefix(200))
            entry.lastErrorAt = now
        }
        entries[source.rawValue] = entry
        save()
    }

    func today(_ source: ResearchSource, now: Date = Date()) -> Int {
        guard let entry = entries[source.rawValue], entry.day == Self.dayKey(now) else { return 0 }
        return entry.dayCount
    }

    func thisMonth(_ source: ResearchSource, now: Date = Date()) -> Int {
        guard let entry = entries[source.rawValue], entry.month == Self.monthKey(now) else { return 0 }
        return entry.monthCount
    }

    func entry(_ source: ResearchSource) -> Entry? { entries[source.rawValue] }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}

/// Aufruf aus beliebigen Threads (Recherche-Pipeline).
nonisolated enum ResearchUsage {
    static func record(_ source: ResearchSource, error: String? = nil) {
        Task { @MainActor in ResearchUsageStore.shared.record(source, error: error) }
    }
}

private extension ISO8601DateFormatter {
    /// Datum in der lokalen Zeitzone („2026-10-14“) – der Tageszähler springt um Mitternacht.
    nonisolated(unsafe) static let localDay: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        formatter.timeZone = .current
        return formatter
    }()
}
