import AppKit
import Foundation

/// Erlaubte Dateitypen für Downloads aus Python (Einstellungen → Tools → Erweitert). Python prüft
/// den `Content-Type` jeder Antwort gegen diese Liste, bevor der Code die Daten bekommt.
nonisolated enum DownloadFileType: String, CaseIterable, Codable, Identifiable, Sendable {
    case pdf, text, data, word, excel, images, science, archives

    var id: String { rawValue }

    static let defaults: [DownloadFileType] = [.pdf, .text, .data, .word, .excel, .images, .science]

    var label: String {
        switch self {
        case .pdf: "PDF"
        case .text: "Text und CSV"
        case .data: "JSON und XML"
        case .word: "Word und Textdokumente"
        case .excel: "Excel und Tabellen"
        case .images: "Bilder"
        case .science: "Wissenschaftliche Datenformate"
        case .archives: "Archive (ZIP, gzip)"
        }
    }

    var help: String {
        switch self {
        case .pdf: "PDF-Dokumente."
        case .text: "Klartext, CSV, TSV, Markdown und HTML-Seiten."
        case .data: "JSON, GeoJSON, XML – typisch für Daten-APIs (z. B. Wetter)."
        case .word: "Word (.doc, .docx), OpenDocument-Text, RTF."
        case .excel: "Excel (.xls, .xlsx) und OpenDocument-Tabellen."
        case .images: "PNG, JPEG, GIF, WebP, SVG. Von Python gespeicherte Bilder erscheinen im Chat."
        case .science: "Parquet, NetCDF, HDF5, GRIB – z. B. Wetter- und Klimadaten."
        case .archives: "ZIP, gzip und tar. Archive mit Programmen werden immer entfernt."
        }
    }

    /// Content-Type-Präfixe, die zu diesem Typ gehören (klein geschrieben).
    var mimePrefixes: [String] {
        switch self {
        case .pdf: ["application/pdf"]
        case .text: ["text/", "application/csv"]
        case .data: ["application/json", "application/xml", "application/geo+json", "application/ld+json",
                     "application/x-ndjson", "application/vnd.geo+json", "application/problem+json", "+json", "+xml"]
        case .word: ["application/msword", "application/vnd.openxmlformats-officedocument.wordprocessingml",
                     "application/vnd.oasis.opendocument.text", "application/rtf"]
        case .excel: ["application/vnd.ms-excel", "application/vnd.openxmlformats-officedocument.spreadsheetml",
                      "application/vnd.oasis.opendocument.spreadsheet"]
        case .images: ["image/"]
        case .science: ["application/x-parquet", "application/vnd.apache.parquet", "application/x-netcdf",
                        "application/netcdf", "application/x-hdf5", "application/x-hdf", "application/grib", "application/x-grib"]
        case .archives: ["application/zip", "application/x-zip-compressed", "application/gzip", "application/x-gzip",
                         "application/x-tar"]
        }
    }
}

/// Dateiprüfung für Downloads aus Python: nach jedem Lauf mit Internet werden neue Dateien im
/// Arbeitsordner am Inhalt geprüft und Programme, Installer, Disk-Images und Skripte entfernt –
/// Archive zusätzlich, wenn sie nicht erlaubt sind oder Programme enthalten.
nonisolated enum DataDownloader {

    /// Prüft neue Dateien nach einem Lauf. Liefert die entfernten Dateien mit Grund.
    static func sweep(directory: URL, modifiedSince start: Date, keep: Set<String>,
                      allowArchives: Bool) -> [(name: String, reason: String)] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var removed: [(String, String)] = []
        for name in names where !keep.contains(name) && !name.hasSuffix(".py") && name != "sandbox.sb" {
            let url = directory.appendingPathComponent(name)
            guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                  (attributes[.type] as? FileAttributeType) == .typeRegular,
                  let modified = attributes[.modificationDate] as? Date, modified >= start.addingTimeInterval(-1),
                  let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let head = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
            try? handle.close()
            let check = classify(head)
            var reason: String?
            if !check.allowed && check.kind != "unbekannte Binärdateien" {
                reason = check.kind
            } else if check.kind == "ZIP-Archiv" || check.kind == "gzip" {
                let isOffice = check.kind == "ZIP-Archiv" && officeZip(head)
                if !isOffice && !allowArchives {
                    reason = "Archive (in den Einstellungen nicht erlaubt)"
                } else if check.kind == "ZIP-Archiv", let data = try? Data(contentsOf: url), let blocked = blockedZipEntry(data) {
                    reason = "Archive mit Programmen (\(blocked))"
                }
            }
            if let reason {
                try? fm.removeItem(at: url)
                removed.append((name, reason))
            } else {
                // Heruntergeladenes nie ausführbar ablegen.
                try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            }
        }
        return removed
    }

    /// Word/Excel (.docx/.xlsx) sind technisch ZIP-Archive – die gehören zu den Dokumenten.
    static func officeZip(_ head: Data) -> Bool {
        let text = String(decoding: head, as: UTF8.self)
        return text.contains("[Content_Types].xml") || text.contains("word/") || text.contains("xl/")
            || text.contains("mimetypeapplication/vnd.oasis.opendocument")
    }

    // MARK: Dateityp nach Inhalt (nicht nach Endung)

    /// Erlaubt sind Daten, Text, Bilder, PDF und Archive mit Daten. Programme, Installer,
    /// Disk-Images und Skripte mit Shebang werden abgelehnt.
    static func classify(_ data: Data) -> (allowed: Bool, kind: String) {
        let bytes = [UInt8](data.prefix(16))
        func starts(_ prefix: [UInt8]) -> Bool { bytes.count >= prefix.count && Array(bytes.prefix(prefix.count)) == prefix }

        // Gesperrt: ausführbare Formate und Installer.
        let machO: [[UInt8]] = [[0xFE, 0xED, 0xFA, 0xCE], [0xFE, 0xED, 0xFA, 0xCF], [0xCE, 0xFA, 0xED, 0xFE],
                                [0xCF, 0xFA, 0xED, 0xFE], [0xCA, 0xFE, 0xBA, 0xBE]]
        if machO.contains(where: starts) { return (false, "Programme (Mach-O)") }
        if starts([0x7F, 0x45, 0x4C, 0x46]) { return (false, "Programme (ELF)") }
        if starts([0x4D, 0x5A]) { return (false, "Windows-Programme") }
        if starts(Array("xar!".utf8)) { return (false, "Installer-Pakete (.pkg)") }
        if starts(Array("#!".utf8)) { return (false, "Skripte") }
        if data.count > 512, data.suffix(512).prefix(4) == Data("koly".utf8) { return (false, "Disk-Images (.dmg)") }

        // Erlaubt: bekannte Daten- und Medienformate.
        if starts(Array("%PDF".utf8)) { return (true, "PDF") }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return (true, "PNG") }
        if starts([0xFF, 0xD8, 0xFF]) { return (true, "JPEG") }
        if starts(Array("GIF8".utf8)) { return (true, "GIF") }
        if starts(Array("RIFF".utf8)) { return (true, "RIFF (z. B. WebP)") }
        if starts([0x50, 0x4B, 0x03, 0x04]) || starts([0x50, 0x4B, 0x05, 0x06]) { return (true, "ZIP-Archiv") }
        if starts([0x1F, 0x8B]) { return (true, "gzip") }
        if starts(Array("PAR1".utf8)) { return (true, "Parquet") }
        if starts(Array("CDF".utf8)) || starts([0x89, 0x48, 0x44, 0x46]) { return (true, "NetCDF/HDF5") }
        if starts(Array("GRIB".utf8)) { return (true, "GRIB") }
        if starts([0xD0, 0xCF, 0x11, 0xE0]) { return (true, "Excel (alt)") }
        if starts(Array("SQLite format".utf8)) { return (true, "SQLite") }

        // Text (CSV, JSON, XML, HTML, TXT): gültiges UTF-8 bzw. Latin-1 ohne Steuerzeichen.
        let sample = data.prefix(64 * 1024)
        if let text = String(data: sample, encoding: .utf8) ?? String(data: sample, encoding: .isoLatin1),
           !text.unicodeScalars.contains(where: { $0.value < 0x09 || ($0.value > 0x0D && $0.value < 0x20) }) {
            return (true, "Text")
        }
        return (false, "unbekannte Binärdateien")
    }

    /// ZIP: Einträge, die Programme oder App-Bundles sind, sperren das ganze Archiv.
    static func blockedZipEntry(_ data: Data) -> String? {
        let blockedSuffixes = [".pkg", ".dmg", ".command", ".sh", ".exe", ".dylib", ".so", ".bin", ".jar", ".scpt"]
        // Namen der Einträge stehen im Klartext hinter den lokalen Datei-Headern.
        var offset = 0
        let bytes = [UInt8](data)
        while offset + 30 <= bytes.count, bytes[offset] == 0x50, bytes[offset + 1] == 0x4B,
              bytes[offset + 2] == 0x03, bytes[offset + 3] == 0x04 {
            let nameLength = Int(bytes[offset + 26]) | Int(bytes[offset + 27]) << 8
            let extraLength = Int(bytes[offset + 28]) | Int(bytes[offset + 29]) << 8
            let compressed = Int(bytes[offset + 18]) | Int(bytes[offset + 19]) << 8 | Int(bytes[offset + 20]) << 16 | Int(bytes[offset + 21]) << 24
            let nameStart = offset + 30
            guard nameStart + nameLength <= bytes.count else { break }
            let name = String(decoding: bytes[nameStart..<nameStart + nameLength], as: UTF8.self).lowercased()
            if name.contains(".app/") { return ".app" }
            if let suffix = blockedSuffixes.first(where: { name.hasSuffix($0) }) { return suffix }
            // Größe unbekannt (Streaming-ZIP): weiter geht es nur über das zentrale Verzeichnis – dann stoppen.
            if compressed == 0 && (Int(bytes[offset + 6]) & 0x08) != 0 { break }
            offset = nameStart + nameLength + extraLength + compressed
        }
        return nil
    }
}

// MARK: - Freigaben

/// Freigabe-Dialog pro Download: Einmal erlauben, immer für diese Domain erlauben oder ablehnen.
/// Dauerhaft erlaubte Domains liegen in den Einstellungen (Tools → Downloads aus Python).
@MainActor
final class DownloadPermissions {
    static let shared = DownloadPermissions()

    /// Liefert/speichert die dauerhaft erlaubten Domains (vom ViewModel gesetzt).
    var allowedDomains: () -> [String] = { [] }
    var addAllowedDomain: (String) -> Void = { _ in }

    func isAllowed(host: String) -> Bool {
        allowedDomains().contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func requestPermission(host: String) async -> Bool {
        if isAllowed(host: host) { return true }
        // Tests öffnen nie einen Dialog: Unbekannte Domains gelten dort als abgelehnt.
        if AppStorageLocation.isRunningUnitTests { return false }
        let alert = NSAlert()
        alert.messageText = "Python möchte ins Internet"
        alert.informativeText = """
        Ein Python-Skript des Modells möchte eine Verbindung zu

        \(host)

        aufbauen, z. B. um Daten herunterzuladen. Erlaube nur Domains, denen du vertraust – über eine \
        erlaubte Verbindung könnte Python auch Daten senden. Heruntergeladene Programme werden nie ausgeführt.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Einmal erlauben")
        alert.addButton(withTitle: "Immer erlauben")
        alert.addButton(withTitle: "Ablehnen")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return true
        case .alertSecondButtonReturn:
            addAllowedDomain(host)
            return true
        default:
            return false
        }
    }
}

