import Foundation
import os

/// Zentrales, kategorisiertes Logging (ersetzt die verstreuten `print`-Aufrufe).
/// Log-Level im Konsole.app-Filter: subsystem "com.pymolt.LernAssist".
nonisolated enum AppLog {
    static let subsystem = "com.pymolt.LernAssist"

    /// Chat-Pipeline: Senden, Streaming, Tool-Continuation, Cancel.
    static let chat = Logger(subsystem: subsystem, category: "chat")
    /// Tool-Ausführung (Registry, Web-Suche, Coding-Sandbox).
    static let tools = Logger(subsystem: subsystem, category: "tools")
    /// Services: Screenshot, Dokumente, LM-Studio-Modellverwaltung, Netzwerk.
    static let services = Logger(subsystem: subsystem, category: "services")
    /// Persistenz: Session-/Settings-Speicherung, Migrationswarnungen.
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    /// UI-Lebenszyklus und App-Einstieg.
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
