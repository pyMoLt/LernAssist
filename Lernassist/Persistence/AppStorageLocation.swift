import Foundation

/// Zentrale Pfade für die lokale Ablage von Einstellungen, Chats und Bildern.
/// Alles liegt unter `~/Library/Application Support/LernAssist/` – reine JSON-/PNG-Dateien,
/// bewusst ohne Datenbank, damit es unkompliziert bleibt und einfach zu inspizieren/sichern ist.
enum AppStorageLocation {
    static let root: URL = {
        // Test-/Demo-Ablage: Mit LERNASSIST_DATA_DIR läuft die App komplett getrennt von den echten Chats.
        if let custom = ProcessInfo.processInfo.environment["LERNASSIST_DATA_DIR"], !custom.isEmpty {
            let dir = URL(fileURLWithPath: custom, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("LernAssist", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let settingsFile = root.appendingPathComponent("settings.json")

    static let sessionsDir: URL = {
        let dir = root.appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let archiveDir: URL = {
        let dir = root.appendingPathComponent("archive", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let trashDir: URL = {
        let dir = root.appendingPathComponent("trash", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let imagesDir: URL = {
        let dir = root.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func sessionFile(id: UUID, archived: Bool) -> URL {
        (archived ? archiveDir : sessionsDir).appendingPathComponent("\(id.uuidString).json")
    }

    static func trashedSessionFile(id: UUID) -> URL {
        trashDir.appendingPathComponent("\(id.uuidString).json")
    }

    static func imageFile(id: UUID) -> URL {
        imagesDir.appendingPathComponent("\(id.uuidString).png")
    }

    /// Schreibt Daten atomar (Temp-Datei + Rename), damit ein Absturz während des Schreibens
    /// nie eine halb geschriebene / korrupte Datei hinterlässt.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}
