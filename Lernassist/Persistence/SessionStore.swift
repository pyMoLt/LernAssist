import Foundation
import os

/// Lädt/speichert Chat-Sessions als je eine JSON-Datei unter `sessions/` (aktiv)
/// bzw. `archive/` (archiviert). Bilder werden NICHT im JSON mitgeführt (das würde
/// pro Screenshot bis zu ~7 MB Base64 in jede Chat-Datei schreiben) – stattdessen
/// landen sie einmalig als PNG unter `images/`, referenziert über `imageID`.
final class SessionStore {
    static let shared = SessionStore()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Laden

    func loadAllActive() -> [ChatSession] {
        loadAll(from: AppStorageLocation.sessionsDir)
    }

    func loadAllArchived() -> [ChatSession] {
        loadAll(from: AppStorageLocation.archiveDir)
    }

    func loadAllTrashed() -> [ChatSession] {
        loadAll(from: AppStorageLocation.trashDir)
    }

    private func loadAll(from dir: URL) -> [ChatSession] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }

        var sessions: [ChatSession] = []
        for url in files where url.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: url)
                var session = try decoder.decode(ChatSession.self, from: data)
                // Tool-Ausführungen können einen App-Neustart nicht überleben. Ein persistierter
                // Call ohne Ergebnis ist daher nie mehr „in Arbeit“, sondern verwaist. Ohne diese
                // Migration zeigte ToolCallBadge nach jedem Neustart einen Endlos-Spinner – auch
                // wenn die Antwort längst mit dem Tool-Runden-Limit abgeschlossen worden war.
                if Self.resolveInterruptedToolCalls(in: &session) {
                    persist(session, to: url)
                }
                sessions.append(session)
            } catch {
                // Korrupte Session-Dateien wurden vorher still verworfen (Audit P2) – der Chat
                // "verschwand" damit ohne jede Spur. Jetzt wird der Vorfall inkl. Dateiname geloggt.
                AppLog.persistence.error("Session-Datei konnte nicht geladen werden (\(url.lastPathComponent)): \(error.localizedDescription)")
            }
        }
        // Neueste zuerst – entspricht der bisherigen Reihenfolge (neue Chats werden vorne eingefügt).
        return sessions.sorted { $0.date > $1.date }
    }

    /// Schließt Tool-Aufrufe, die in einer gespeicherten Session ohne Ergebnis liegen.
    /// Rückgabewert signalisiert, ob die aufrufende Lade-Logik die bereinigte Session speichern
    /// muss. Die Funktion ist intern, damit die Persistenz-Migration regressionsgetestet werden
    /// kann, ohne auf das Application-Support-Verzeichnis zuzugreifen.
    @discardableResult
    static func resolveInterruptedToolCalls(in session: inout ChatSession) -> Bool {
        let interruptionMessage = "Unterbrochen: Die App wurde beendet, bevor dieser Tool-Aufruf abgeschlossen war."
        var didResolve = false

        for messageIndex in session.messages.indices {
            guard var calls = session.messages[messageIndex].toolCalls else { continue }
            for callIndex in calls.indices where calls[callIndex].result == nil {
                calls[callIndex].result = interruptionMessage
                didResolve = true
            }
            session.messages[messageIndex].toolCalls = calls
        }
        return didResolve
    }

    // MARK: - Speichern

    /// Persistiert eine Session. Lagert dabei enthaltene Bilder (falls noch nicht auf Platte) aus
    /// und schreibt die JSON-Datei ohne die Base64-Bilddaten.
    func save(_ session: ChatSession, archived: Bool = false) {
        persist(session, to: AppStorageLocation.sessionFile(id: session.id, archived: archived))
    }

    @discardableResult
    private func writeImageIfNeeded(base64: String, id: UUID) -> Bool {
        let url = AppStorageLocation.imageFile(id: id)
        guard !FileManager.default.fileExists(atPath: url.path) else { return true }
        guard let data = Data(base64Encoded: base64) else { return true }
        // Atomar wie das zugehörige JSON (Audit P2): Ein halb geschriebenes PNG wäre eine
        // stumme, unbrauchbare Leiche in images/.
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            // Audit M19: Vorher `try?` – der Schreibfehler war still, aber das JSON strippte
            // die Base64 trotzdem → das JSON referenzierte ein fehlendes PNG, irreversibler
            // Bildverlust. Caller hält die Base64 bei Misserfolg jetzt im JSON.
            AppLog.persistence.error("Bild \(id.uuidString) konnte nicht geschrieben werden: \(error.localizedDescription)")
            return false
        }
    }

    /// Entfernt eine Datei und loggt Misserfolg (Audit M18): Das frühere `try?` verschluckte
    /// den Fehler – blieb die Quelldatei z.B. beim Archivieren liegen, existierte die Session
    /// nach dem nächsten Start DOPPELT (sessions/ UND archive/) mit auseinanderlaufenden Kopien.
    private func removeLoggingFailure(at url: URL, context: String) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            AppLog.persistence.error("Konnte \(url.lastPathComponent) nicht entfernen (\(context)): \(error.localizedDescription) – Duplikat-Risiko nach dem nächsten App-Start.")
        }
    }

    // MARK: - Löschen / Archivieren
    // (Audit 2.7: `delete(id:session:)` hatte 0 Aufrufer – toter Code, entfernt. Aktive und
    // archivierte Sessions werden über trash()/deletePermanently(...) entfernt.)

    /// Verschiebt eine Session von `sessions/` nach `archive/`.
    func archive(_ session: ChatSession) {
        save(session, archived: true)
        removeLoggingFailure(at: AppStorageLocation.sessionFile(id: session.id, archived: false), context: "Archivieren")
    }

    /// Verschiebt eine Session von `archive/` zurück nach `sessions/`.
    func unarchive(_ session: ChatSession) {
        save(session, archived: false)
        removeLoggingFailure(at: AppStorageLocation.sessionFile(id: session.id, archived: true), context: "Dearchivieren")
    }

    /// Entfernt eine archivierte Session endgültig (inkl. ihrer Bilder).
    func deletePermanently(archivedSession: ChatSession) {
        removeLoggingFailure(at: AppStorageLocation.sessionFile(id: archivedSession.id, archived: true), context: "Endgültiges Löschen")
        removeImagesNoLongerReferenced(by: archivedSession)
    }

    // MARK: - Papierkorb

    /// Persistiert eine Session in `trash/` (gleiches Vorgehen wie `save`: Bilder liegen separat
    /// unter `images/`, das JSON referenziert sie nur über `imageID`).
    private func saveTrashed(_ session: ChatSession) {
        persist(session, to: AppStorageLocation.trashedSessionFile(id: session.id))
    }

    /// Gemeinsame Persistenz-Logik für save()/saveTrashed() (Audit 2.7: saveTrashed war ein
    /// nahezu wortgleiches Duplikat von save). Schreibt Bilder aus, strippt Base64 aus dem JSON
    /// und schreibt atomar. Fehler werden geloggt statt stillgeschluckt (Audit P2).
    private func persist(_ session: ChatSession, to url: URL) {
        var strippedSession = session
        strippedSession.messages = session.messages.map { msg -> ChatMessage in
            var m = msg
            if let imgID = m.imageID, let b64 = m.imageBase64 {
                if writeImageIfNeeded(base64: b64, id: imgID) {
                    // liegt jetzt auf Platte, imageID genügt zum Nachladen
                    m.imageBase64 = nil
                }
                // Audit M19: Schlägt das PNG-Schreiben fehl, bleibt die Base64 im JSON –
                // sonst referenzierte das JSON ein fehlendes Bild (irreversibler Verlust).
            }
            return m
        }

        do {
            let data = try encoder.encode(strippedSession)
            try AppStorageLocation.writeAtomically(data, to: url)
        } catch {
            // Vorher stummes try? (Audit P2): Bei Disk-Full o. Ä. ging der Chat kommentarlos
            // verloren. Jetzt wenigstens diagnostizierbar geloggt.
            AppLog.persistence.error("Session \(session.id.uuidString) konnte nicht gespeichert werden: \(error.localizedDescription)")
        }
    }

    /// Verschiebt eine Session in den Papierkorb – wahlweise von `sessions/` (aktiv) oder
    /// `archive/` (archiviert), je nach `wasArchived`. Ersetzt für aktive Sessions das frühere
    /// sofortige, endgültige Löschen ohne Zwischenschritt.
    func trash(_ session: ChatSession, wasArchived: Bool) {
        saveTrashed(session)
        removeLoggingFailure(at: AppStorageLocation.sessionFile(id: session.id, archived: wasArchived), context: "Papierkorb")
    }

    /// Stellt eine Session aus dem Papierkorb wieder her, zurück nach `sessions/`.
    func restoreFromTrash(_ session: ChatSession) {
        save(session, archived: false)
        removeLoggingFailure(at: AppStorageLocation.trashedSessionFile(id: session.id), context: "Wiederherstellen")
    }

    /// Entfernt eine Session aus dem Papierkorb endgültig (inkl. ihrer Bilder). Erst hier ist das
    /// Löschen wirklich irreversibel.
    func deletePermanently(trashedSession: ChatSession) {
        removeLoggingFailure(at: AppStorageLocation.trashedSessionFile(id: trashedSession.id), context: "Endgültiges Löschen aus Papierkorb")
        removeImagesNoLongerReferenced(by: trashedSession)
    }

    /// Entfernt Bilddateien erst, wenn keine gespeicherte Session mehr darauf verweist.
    /// Chat-Zweige kopieren ihre Nachrichten (und damit zunächst auch `imageID`s); ein blindes
    /// Löschen beim Entfernen des Ursprungs-Chats ließ Screenshots im noch vorhandenen Zweig
    /// verschwinden. Die JSON-Datei der gerade gelöschten Session ist zu diesem Zeitpunkt schon
    /// weg, deshalb genügt der Scan über aktiv/Archiv/Papierkorb.
    private func removeImagesNoLongerReferenced(by deletedSession: ChatSession) {
        let candidates = Self.imageIDs(in: deletedSession)
        guard !candidates.isEmpty else { return }

        let referenced = referencedImageIDs()
        for imageID in candidates where !referenced.contains(imageID) {
            do {
                try FileManager.default.removeItem(at: AppStorageLocation.imageFile(id: imageID))
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Ein fehlendes Bild ist bereits aufgeräumt; kein Fehlerzustand.
            } catch {
                AppLog.persistence.error("Bilddatei \(imageID.uuidString) konnte nicht gelöscht werden: \(error.localizedDescription)")
            }
        }
    }

    /// Liest ausschließlich die Bild-Referenzen aller verbleibenden Session-Dateien. Fehlerhafte
    /// Dateien werden wie beim regulären Laden geloggt, blockieren aber nicht das Aufräumen
    /// anderer, gültiger Sessions.
    /// Bilder einer Session: Nachrichten und Karteikarten (Bildkarten haben eine eigene Kopie).
    static func imageIDs(in session: ChatSession) -> Set<UUID> {
        var ids = Set(session.messages.compactMap(\.imageID))
        // Abbildungen aus der Recherche ([B#]) liegen ebenfalls im Bildspeicher.
        for message in session.messages {
            for call in message.toolCalls ?? [] { ids.formUnion((call.researchImages ?? []).map(\.imageID)) }
        }
        for set in session.flashcardSets ?? [] {
            ids.formUnion(set.cards.compactMap(\.imageID))
        }
        return ids
    }

    private func referencedImageIDs() -> Set<UUID> {
        let directories = [AppStorageLocation.sessionsDir, AppStorageLocation.archiveDir, AppStorageLocation.trashDir]
        var result = Set<UUID>()

        for directory in directories {
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                continue
            }
            for file in files where file.pathExtension == "json" {
                do {
                    let session = try decoder.decode(ChatSession.self, from: Data(contentsOf: file))
                    result.formUnion(Self.imageIDs(in: session))
                } catch {
                    AppLog.persistence.error("Session-Datei konnte beim Bild-Aufräumen nicht gelesen werden (\(file.lastPathComponent)): \(error.localizedDescription)")
                }
            }
        }
        return result
    }
}
