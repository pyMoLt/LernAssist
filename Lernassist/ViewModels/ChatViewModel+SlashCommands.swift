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

        // MARK: Lernen & Recherche (LernAssist 2.0)

        registry.register(command: SlashCommand(
            id: "search", aliases: ["web", "w"], description: "Gezielt im Web recherchieren (mit Belegen)", paramHint: "<Thema>",
            action: { [weak self] arg in
                self?.sendSlashPrompt(arg, usage: "/search <Thema>") {
                    "Recherchiere mit `web_search` zu „\($0)“ und fasse die wichtigsten belegten Fakten mit Quellenangaben [W#] zusammen."
                }
            }
        ))

        registry.register(command: SlashCommand(
            id: "quiz", aliases: ["q", "abfragen"], description: "Lass dich abfragen (interaktive Karten)", paramHint: "[Thema]",
            action: { [weak self] arg in
                let topic = arg.trimmingCharacters(in: .whitespacesAndNewlines)
                let focus = topic.isEmpty ? "zum Stoff dieses Chats" : "zu „\(topic)“"
                self?.sendMessage(text: "Frag mich \(focus) ab: Stelle jede Frage einzeln als `quiz_card` (nie als reinen Text), warte jeweils auf meine Antwort, gib kurzes Feedback und stelle dann die nächste Frage wieder als `quiz_card`.", displayText: "/quiz" + (arg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : " " + arg.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        ))

        registry.register(command: SlashCommand(
            id: "simple", aliases: ["eli5", "einfacher"], description: "Letzte Erklärung einfacher wiederholen", paramHint: nil,
            action: { [weak self] _ in
                self?.sendMessage(text: "Erkläre das noch einmal deutlich einfacher – mit einer Analogie aus dem Alltag und ohne Fachjargon.", displayText: "/simple")
            }
        ))

        registry.register(command: SlashCommand(
            id: "summary", aliases: ["sum", "lernzettel"], description: "Lernzusammenfassung des Chats", paramHint: "[Fokus]",
            action: { [weak self] arg in
                let focus = arg.trimmingCharacters(in: .whitespacesAndNewlines)
                self?.sendMessage(text: "Erstelle eine kompakte Lernzusammenfassung dieses Chats: Kernbegriffe, wichtigste Zusammenhänge, Merksätze und typische Prüfungsfragen\(focus.isEmpty ? "" : " mit Fokus auf „\(focus)“").", displayText: "/summary" + (arg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : " " + arg.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        ))

        registry.register(command: SlashCommand(
            id: "diagram", aliases: ["diagramm", "mermaid"], description: "Ablauf als Diagramm darstellen", paramHint: "[Thema]",
            action: { [weak self] arg in
                let topic = arg.trimmingCharacters(in: .whitespacesAndNewlines)
                self?.sendMessage(text: "Stelle \(topic.isEmpty ? "das zuletzt besprochene Thema" : "„\(topic)“") als übersichtliches Mermaid-Diagramm dar (```mermaid-Codeblock, flowchart oder sequenceDiagram) und erkläre es kurz.", displayText: "/diagram" + (arg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : " " + arg.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        ))

        registry.register(command: SlashCommand(
            id: "mode", aliases: ["modus"], description: "Lernmodus wechseln", paramHint: "<anfänger|detailliert|prüfung|tutor|sokratisch|kompakt|visuell>",
            action: { [weak self] arg in self?.handleModeCommand(arg) }
        ))

        registry.register(command: SlashCommand(
            id: "think", aliases: ["denken"], description: "Denkprozess des Modells an/aus", paramHint: "<an|aus|standard>",
            action: { [weak self] arg in self?.handleThinkCommand(arg) }
        ))

        registry.register(command: SlashCommand(
            id: "retry", aliases: ["r", "nochmal"], description: "Letzte Antwort neu erzeugen", paramHint: nil,
            action: { [weak self] _ in self?.regenerateLastAnswer() }
        ))

        registry.register(command: SlashCommand(
            id: "tools", aliases: ["t"], description: "Aktive Tools anzeigen", paramHint: nil,
            action: { [weak self] _ in
                let lines = ToolRegistry.shared.tools.map { "- \($0.isEnabled ? "✅" : "⬜️") **\($0.displayName)** (`\($0.name)`)" }
                self?.addSystemMessage(text: "**Tools:**\n" + lines.joined(separator: "\n") + "\n\nÄndern: `/settings tools`")
            }
        ))

        registry.register(command: SlashCommand(
            id: "screenshot", aliases: ["shot", "ss"], description: "Bildschirmbereich aufnehmen", paramHint: nil,
            action: { _ in NotificationCenter.default.post(name: .screenshotRequested, object: nil) }
        ))

        registry.register(command: SlashCommand(
            id: "help", aliases: ["h", "?"], description: "Verfügbare Befehle anzeigen", paramHint: nil,
            action: { [weak self] _ in
                guard let self else { return }
                // Aus der Registry erzeugt – neue Befehle erscheinen automatisch in der Hilfe.
                let lines = self.slashCommandRegistry.commands.map { cmd -> String in
                    let usage = "/" + cmd.id + (cmd.paramHint.map { " " + $0 } ?? "")
                    let aliases = cmd.aliases.isEmpty ? "" : " (auch " + cmd.aliases.map { "/" + $0 }.joined(separator: ", ") + ")"
                    return "- `\(usage)` — \(cmd.description)\(aliases)"
                }
                self.addSystemMessage(text: "**Verfügbare Slash-Befehle:**\n" + lines.joined(separator: "\n"))
            }
        ))
    }

    /// Schickt einen Slash-Befehl mit Pflichtargument als Prompt; ohne Argument ein Hinweis.
    private func sendSlashPrompt(_ arg: String, usage: String, _ prompt: (String) -> String) {
        let topic = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else {
            addSystemMessage(text: "Bitte ein Thema angeben: `\(usage)`")
            return
        }
        let name = usage.split(separator: " ").first.map(String.init) ?? usage
        sendMessage(text: prompt(topic), displayText: "\(name) \(topic)")
    }

    // MARK: - /mode, /think, /retry

    static func learningStyle(matching raw: String) -> LearningStyle? {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        let aliases: [String: LearningStyle] = [
            "anfänger": .beginner, "anfaenger": .beginner, "einfach": .beginner, "beginner": .beginner,
            "detailliert": .detailed, "detail": .detailed, "tief": .detailed,
            "prüfung": .exam, "pruefung": .exam, "exam": .exam, "prüfungsrelevant": .exam,
            "tutor": .tutor, "sokratisch": .socratic, "socratic": .socratic,
            "kompakt": .compact, "kurz": .compact, "visuell": .visual, "visual": .visual,
        ]
        if let style = aliases[q] { return style }
        return LearningStyle.allCases.first { $0.rawValue.lowercased().hasPrefix(q) }
    }

    func handleModeCommand(_ arg: String) {
        guard let style = Self.learningStyle(matching: arg) else {
            let list = LearningStyle.allCases.map { "- \($0.rawValue)" }.joined(separator: "\n")
            addSystemMessage(text: "Aktueller Modus: **\(learningStyle.rawValue)**\n\nVerfügbar:\n\(list)\n\nz. B. `/mode tutor`")
            return
        }
        learningStyle = style
        saveSettings()
        addSystemMessage(text: "Lernmodus: **\(style.rawValue)**")
    }

    func handleThinkCommand(_ arg: String) {
        guard let idx = profiles.firstIndex(where: { $0.id == activeProfileID }) else { return }
        let q = arg.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mode: ThinkingMode?
        switch q {
        case "an", "on", "ja": mode = .on
        case "aus", "off", "nein": mode = .off
        case "standard", "default", "auto": mode = .serverDefault
        default: mode = nil
        }
        guard let mode else {
            addSystemMessage(text: "Thinking für „\(profiles[idx].name)“: **\(profiles[idx].thinkingMode.label)**. Ändern mit `/think an`, `/think aus` oder `/think standard`.")
            return
        }
        profiles[idx].thinkingMode = mode
        if mode == .on, profiles[idx].thinkingBudget == nil { profiles[idx].thinkingBudget = 4_096 }
        saveSettings()
        addSystemMessage(text: "Thinking für „\(profiles[idx].name)“: **\(mode.label)**")
    }

    /// Verwirft die letzte Antwort und erzeugt sie zur selben Frage neu.
    func regenerateLastAnswer() {
        guard !isStreaming,
              let idx = sessions.firstIndex(where: { $0.id == activeSessionId }),
              let lastUser = sessions[idx].messages.lastIndex(where: { $0.role == "user" }) else {
            addSystemMessage(text: "Es gibt keine Antwort, die neu erzeugt werden könnte.")
            return
        }
        let lastUserMessage = sessions[idx].messages[lastUser]
        sessions[idx].messages.removeSubrange(lastUser...)
        sendMessage(text: lastUserMessage.content, imageBase64: Self.imagePayloadBase64(for: lastUserMessage))
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

        let dialog = session.messages.filter { $0.role == "user" || $0.role == "assistant" }
        let history = Self.compactionTranscript(of: dialog)

        let trimmedFocus = focus.trimmingCharacters(in: .whitespacesAndNewlines)
        let focusInstruction = trimmedFocus.isEmpty ? "" : " Lege dabei besonderen Fokus auf: \(trimmedFocus)."
        let targetTokens = min(max(compactSummaryTokens, 1_000), 16_000)
        let targetWords = targetTokens * 2 / 3

        let summaryRequest = """
Fasse das folgende Lerngespräch so zusammen, dass es ohne den Originalverlauf vollständig weitergeführt werden kann. \
Behalte alle behandelten Themen, Definitionen, Fakten, Zahlen, Formeln, Erklärungen, Beispiele und Zusammenhänge sowie \
die offenen Fragen und den Wissensstand des Nutzers. Gliedere nach Themen mit Zwischenüberschriften und Stichpunkten. \
Umfang: bis zu etwa \(targetWords) Wörter (≈ \(targetTokens) Tokens) – nutze den Platz für Details statt zu kürzen.\(focusInstruction) \
Antworte NUR mit der Zusammenfassung, ohne Einleitung:

\(history)
"""
        let keepCount = min(max(compactKeepLastMessages, 0), 6)
        let kept = Array(dialog.suffix(keepCount))

        Task {
            // Hauptmodell statt Hintergrundmodell: Die Zusammenfassung ersetzt den gesamten
            // Verlauf, Qualität geht hier vor Tempo. sendInvisiblePrompt liefert bei Fehlern nil –
            // dann bleibt der alte Chat unverändert.
            // Bewusst KEIN max_tokens: Die Zielgröße steht nur als Anweisung im Prompt. Eine harte
            // Grenze würde die Zusammenfassung mitten im Satz abschneiden (bei Thinking-Modellen
            // zählen auch die Denk-Tokens mit) – Nutzer, 12.10.2026.
            guard let summary = await sendInvisiblePrompt(summaryRequest, context: []) else {
                await MainActor.run {
                    addSystemMessage(text: "Zusammenfassung fehlgeschlagen – Endpunkt nicht erreichbar. Der Chat bleibt unverändert.")
                }
                return
            }
            await MainActor.run {
                createNewChat()
                guard let idx = sessions.firstIndex(where: { $0.id == activeSessionId }) else { return }
                sessions[idx].title = String("Zusammenfassung: \(session.title)".prefix(40))
                // Als Assistant-Nachricht, NICHT als system: system-Nachrichten sind reine
                // UI-Hinweise und werden aus dem API-Payload gefiltert – der kompaktierte Chat
                // hätte sonst für das Modell keinerlei Kontext (Audit 2026-10-12, Chat-Kern H2).
                sessions[idx].messages.append(ChatMessage(
                    id: UUID(), role: "assistant",
                    content: "Zusammenfassung aus „\(session.title)“:\n\n\(summary)"))
                // Die letzten Nachrichten wörtlich übernehmen (inkl. Screenshot), damit das
                // Modell weiß, woran gerade gearbeitet wurde.
                for msg in kept {
                    sessions[idx].messages.append(ChatMessage(
                        id: UUID(), role: msg.role, content: msg.content,
                        imageBase64: msg.imageBase64, imageID: msg.imageID))
                }
                shouldSuggestCompaction = false // neuer, kompakter Chat (Phase H)
            }
        }
    }

    /// Verlauf als Text für die Zusammenfassung. Nachrichten bleiben vollständig; nur wenn der
    /// gesamte Verlauf sehr groß ist, fallen die ÄLTESTEN zuerst weg. Screenshots gehen als
    /// ihre (eingefrorene) Bildbeschreibung ein.
    static func compactionTranscript(of messages: [ChatMessage], characterBudget: Int = 240_000) -> String {
        var parts: [String] = []
        var used = 0
        for msg in messages.reversed() {
            var text = msg.content
            if msg.imageID != nil || msg.imageBase64 != nil {
                let image = msg.frozenImageContext ?? msg.imageDescription ?? "(ohne Beschreibung)"
                text = "[Screenshot: \(image)]\n" + text
            }
            let line = "[\(msg.role == "user" ? "User" : "Assistent")]: \(text)"
            if used + line.count > characterBudget, !parts.isEmpty { break }
            parts.append(String(line.prefix(characterBudget)))
            used += line.count
        }
        return parts.reversed().joined(separator: "\n\n")
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
