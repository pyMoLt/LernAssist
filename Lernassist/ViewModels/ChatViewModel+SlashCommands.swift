import Foundation

extension ChatViewModel {
    func setupSlashCommands() {
        let registry = slashCommandRegistry

        // Idempotenz für Mehrfachaufruf auf DIESER Instanz (früher war das ein Singleton-Guard
        // über `SlashCommandRegistry.shared`, Audit M13 – siehe SlashCommandRegistry-Doku).
        if !registry.commands.isEmpty { return }

        registry.register(command: SlashCommand(
            id: "compact", aliases: ["c"], description: "Fasst den Chat zusammen und startet eine neue Session", paramHint: "[Fokus]",
            action: { [weak self] arg in
                self?.compact(focus: arg)
            }
        ))

        registry.register(command: SlashCommand(
            id: "clear", aliases: ["new", "n"], description: "Neuer leerer Chat", paramHint: nil,
            action: { [weak self] _ in
                self?.createNewChat()
            }
        ))

        registry.register(command: SlashCommand(
            id: "model", aliases: ["m"], description: "Modell des aktiven Profils anzeigen/wechseln", paramHint: "[name]",
            action: { [weak self] arg in
                self?.handleModelCommand(arg)
            }
        ))

        registry.register(command: SlashCommand(
            id: "endpoint", aliases: ["ep"], description: "Endpunkt-Profil anzeigen/wechseln", paramHint: "[name]",
            action: { [weak self] arg in
                self?.handleEndpointCommand(arg)
            }
        ))

        registry.register(command: SlashCommand(
            id: "youtube", aliases: ["yt"], description: "YouTube-Transkript als Dokument importieren", paramHint: "<URL>",
            action: { [weak self] arg in
                guard let self,
                      let url = URL(string: arg.trimmingCharacters(in: .whitespacesAndNewlines)),
                      YouTubeTranscriptService.videoID(from: url) != nil else {
                    self?.addSystemMessage(text: "Ungültige YouTube-URL – z.B. `/youtube https://www.youtube.com/watch?v=…` (oder einfach die URL direkt senden).")
                    return
                }
                self.importYouTubeTranscript(from: url)
            }
        ))

        registry.register(command: SlashCommand(
            id: "verify", aliases: ["v"], description: "Prüft die letzte KI-Antwort per Websuche", paramHint: nil,
            action: { [weak self] _ in
                self?.verifyLastResponse()
            }
        ))

        registry.register(command: SlashCommand(
            id: "export", aliases: ["ex"], description: "Exportiert den Chat als Markdown", paramHint: nil,
            action: { [weak self] _ in
                self?.exportActiveChat()
            }
        ))

        registry.register(command: SlashCommand(
            id: "settings", aliases: ["s", "config"], description: "Einstellungen öffnen", paramHint: "[tab]",
            action: { arg in
                let tab = SlashCommandHelpers.settingsTabID(for: arg)
                NotificationCenter.default.post(name: .openSettingsRequested, object: nil, userInfo: ["tab": tab])
            }
        ))

        registry.register(command: SlashCommand(
            id: "help", aliases: ["h", "?"], description: "Verfügbare Befehle anzeigen", paramHint: nil,
            action: { [weak self] _ in
                let helpText = """
**Verfügbare Slash-Befehle:**
- `/compact [Fokus]` — Fasst den Chat zusammen und startet eine neue Session (spart Token-Budget), optional mit Fokus-Hinweis
- `/clear` — Neuer leerer Chat
- `/model [name]` — Zeigt/wechselt das Modell des aktiven Profils
- `/endpoint [name]` — Zeigt/wechselt das aktive Endpunkt-Profil
- `/youtube <URL>` — Importiert das YouTube-Transkript als Dokument (oder URL direkt senden)
- `/verify` — Prüft die letzte Antwort aktiv per Websuche
- `/export` — Exportiert den Chat als Markdown-Datei nach ~/Downloads
- `/settings [tab]` — Öffnet die Einstellungen (optional direkt zu einem Tab)
- `/help` — Diese Hilfe
"""
                // War vorher sendMessage(): schickte den Hilfetext als echte User-Nachricht ans
                // Modell (unnötiger Netzwerk-Roundtrip, Modell "antwortete" auf einen statischen
                // Hilfetext) statt ihn wie /model, /endpoint, /export lokal per addSystemMessage
                // anzuzeigen.
                self?.addSystemMessage(text: helpText)
            }
        ))
    }

    // MARK: - /compact

    /// Öffentlicher Einstieg für die Auto-Kompakt-Aktion der Chat-Leiste (Phase H) –
    /// compact(focus:) ist bewusst file-private, dieser Wrapper ist die stabile Kante.
    func compactChat() {
        compact(focus: "")
    }

    /// Fasst den aktuellen Chatverlauf zusammen und startet damit einen neuen, kompakten Chat.
    /// Nutzt `sendInvisiblePrompt()` (wie Quiz/Flashcards), damit die Zusammenfassungs-ANFRAGE
    /// selbst nie als hässliche, riesige User-Nachricht im neuen Chat sichtbar wird – zuvor wurde
    /// der komplette alte Verlauf als sichtbarer erster User-Turn in den neuen Chat gedumpt.
    ///
    /// `focus`: optionaler Text nach `/compact` (z.B. `/compact konzentriere dich auf die
    /// Karteikarten-Bugs`) – analog zum `/compact <Hinweis>`-Muster aus der CLI, lenkt die
    /// Zusammenfassung auf das Genannte, statt (wie zuvor) stillschweigend verworfen zu werden.
    private func compact(focus: String) {
        guard let session = activeSession, !session.messages.isEmpty else { return }

        let history = session.messages
            .filter { $0.role != "system" }
            .map { "[\($0.role == "user" ? "User" : "Assistent")]: \($0.content.prefix(400))" }
            .joined(separator: "\n")

        let trimmedFocus = focus.trimmingCharacters(in: .whitespacesAndNewlines)
        let focusInstruction = trimmedFocus.isEmpty ? "" : " Lege dabei besonderen Fokus auf: \(trimmedFocus)."

        let summaryRequest = """
Fasse das folgende Gespräch in 3-5 prägnanten Sätzen zusammen. Sei möglichst informativ.\(focusInstruction) Antworte NUR mit der Zusammenfassung, ohne Einleitung:

\(history)
"""
        Task {
            // sendInvisiblePrompt liefert bei Netzwerk-/HTTP-Fehlern nil – dann bleibt der
            // alte Chat unverändert, statt einen neuen Chat mit "nil"-Zusammenfassung anzulegen.
            guard let summary = await sendInvisiblePrompt(summaryRequest, context: [], useBackgroundJobModel: true) else {
                await MainActor.run {
                    addSystemMessage(text: "Zusammenfassung fehlgeschlagen – Endpunkt nicht erreichbar. Der Chat bleibt unverändert.")
                }
                return
            }
            await MainActor.run {
                createNewChat()
                guard let idx = sessions.firstIndex(where: { $0.id == activeSessionId }) else { return }
                sessions[idx].title = String("Zusammenfassung: \(session.title)".prefix(40))
                addSystemMessage(text: "Zusammenfassung aus „\(session.title)“:\n\n\(summary)")
                shouldSuggestCompaction = false // neuer, kompakter Chat (Phase H)
            }
        }
    }

    // MARK: - /model

    private func handleModelCommand(_ arg: String) {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let idx = profiles.firstIndex(where: { $0.id == activeProfileID }) else {
            addSystemMessage(text: "Kein aktives Profil vorhanden.")
            return
        }
        if trimmed.isEmpty {
            addSystemMessage(text: "Aktuelles Modell (\(profiles[idx].name)): **\(profiles[idx].model)**")
            return
        }
        // Validierung (Audit M15): Modell-IDs enthalten keine Leerzeichen – ein Name mit
        // Whitespace wäre ein Tippfehler, der später als HTTP 400/404 vom Server käme, ohne
        // dass der Nutzer hier die Ursache sähe.
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            addSystemMessage(text: "Ungültiger Modellname „\(trimmed)“ – Modell-IDs enthalten keine Leerzeichen.")
            return
        }
        let oldModel = profiles[idx].model
        profiles[idx].model = trimmed
        // Kontextfenster-Override des ALTEN Modells verwerfen (Audit M15): Sonst zeigte die
        // MetricsBar künftig das Kontextfenster des vorherigen Modells. Anschließend wird das
        // echte Fenster des neuen Modells automatisch neu abgefragt.
        profiles[idx].contextSizeOverride = nil
        saveSettings()
        refreshContextWindowForActiveProfile()
        addSystemMessage(text: "Modell für „\(profiles[idx].name)“ geändert: \(oldModel) → **\(trimmed)**")
    }

    // MARK: - /endpoint

    private func handleEndpointCommand(_ arg: String) {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let lines = profiles.map { p -> String in
                var tags: [String] = []
                if p.id == activeProfileID { tags.append("aktiv") }
                if p.id == fallbackProfileID { tags.append("fallback") }
                let suffix = tags.isEmpty ? "" : " (\(tags.joined(separator: ", ")))"
                return "- **\(p.name)**\(suffix): \(p.model)"
            }
            addSystemMessage(text: "Verfügbare Profile:\n" + lines.joined(separator: "\n"))
            return
        }
        // Match-Verfeinerung (Audit M15): Der frühere reine Substring-Match traf mit "l" auch
        // "lm-studio" und wechselte damit zum falschen Profil. Jetzt: exakter Treffer (case-
        // insensitive) vor Prefixed-Treffern, und bei MEHRDEUTIGEM Prefix eine Liste statt
        // stummem erstem Treffer.
        let query = trimmed.lowercased()
        let exact = profiles.first(where: { $0.name.lowercased() == query })
        let prefixMatches = profiles.filter { $0.name.lowercased().hasPrefix(query) }
        guard let match = exact ?? (prefixMatches.count == 1 ? prefixMatches.first : nil) else {
            let names = profiles.map { $0.name }.joined(separator: ", ")
            let ambiguous = prefixMatches.count > 1
                ? " Der Begriff ist mehrdeutig (mögliche Treffer: \(prefixMatches.map { $0.name }.joined(separator: ", ")))."
                : ""
            addSystemMessage(text: "Kein eindeutiges Profil namens „\(trimmed)“ gefunden. Verfügbar: \(names).\(ambiguous)")
            return
        }
        activeProfileID = match.id
        saveSettings()
        refreshContextWindowForActiveProfile()
        addSystemMessage(text: "Aktives Profil gewechselt zu **\(match.name)** (\(match.model))")
    }

    // MARK: - /export

    /// Exportiert den aktiven Chat als Markdown-Datei nach ~/Downloads.
    private func exportActiveChat() {
        guard let session = activeSession, !session.messages.isEmpty else {
            addSystemMessage(text: "Nichts zu exportieren – der Chat ist leer.")
            return
        }

        // Markdown-Aufbau zentral in chatMarkdown(for:) (Phase H: gemeinsam mit dem Share-Button).
        let markdown = chatMarkdown(for: session)
        let safeTitle = session.title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let filename = "LernAssist-\(safeTitle)-\(formatter.string(from: Date())).md"

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let fileURL = downloads.appendingPathComponent(filename)

        do {
            try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
            addSystemMessage(text: "Chat exportiert nach: `\(fileURL.path)`")
        } catch {
            addSystemMessage(text: "Export fehlgeschlagen: \(error.localizedDescription)")
        }
    }
}

// MARK: - Helfer

enum SlashCommandHelpers {
    /// Ordnet ein `/settings`-Argument (case-insensitive, deutsch oder englisch) einer Tab-ID zu,
    /// wie sie SettingsView intern verwendet ("Endpoints", "Model", "Learning", ...).
    static func settingsTabID(for arg: String) -> String {
        let key = arg.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let map: [String: String] = [
            "endpoint": "Endpoints", "endpoints": "Endpoints", "endpunkte": "Endpoints",
            "model": "Model", "modell": "Model",
            "learning": "Learning", "lernmodus": "Learning",
            "search": "Search", "websuche": "Search", "suche": "Search",
            "hotkeys": "Hotkeys", "tasten": "Hotkeys",
            "tools": "Tools",
            "advanced": "Advanced", "erweitert": "Advanced",
            "appearance": "Appearance", "erscheinungsbild": "Appearance", "theme": "Appearance",
            "experimental": "Experimental"
        ]
        return map[key] ?? "Endpoints"
    }
}
