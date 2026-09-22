import Foundation
import os

// MARK: - Phase H: Lern- und Chat-Features
//
// Branching, Auto-Kompakt-Angebot, Markdown-Export und YouTube-Transkript-Import. Bewusst als
// eigene Extension-Datei statt im ChatViewModel-Kern (Audit 4: God-Object-Zerlegung).

extension ChatViewModel {

    // MARK: - Chat-Branching

    /// Liefert den echten Kontext für einen Bearbeitungs-Zweig: alles VOR der gewählten
    /// Nutzerfrage. Die Frage selbst wird bewusst nur als Entwurf zurückgegeben, damit sie nach
    /// dem Bearbeiten neu gesendet und nicht doppelt in den Modell-Kontext geschrieben wird.
    static func editingBranchPlan(for messages: [ChatMessage], userMessageID: UUID)
        -> (history: [ChatMessage], draft: String)? {
        guard let userIndex = messages.firstIndex(where: { $0.id == userMessageID }),
              messages[userIndex].role == "user" else { return nil }
        return (Array(messages.prefix(userIndex)), messages[userIndex].content)
    }

    /// Erstellt für das Stift-Icon einen nicht-destruktiven Zweig. Der Ursprungschat bleibt
    /// unverändert; im neuen Zweig ist der Verlauf an der ausgewählten Nutzerfrage abgeschnitten
    /// und deren Text liegt im Eingabefeld bereit. So erhält der nächste Versand wirklich nur den
    /// gewünschten, bereinigten Kontext.
    @discardableResult
    func branchFromUserMessageForEditing(id: UUID) -> String? {
        guard !isStreaming,
              let sessionIdx = sessions.firstIndex(where: { $0.id == activeSessionId }),
              let plan = Self.editingBranchPlan(for: sessions[sessionIdx].messages, userMessageID: id)
        else { return nil }

        let sourceTitle = sessions[sessionIdx].title
        let branchTitle = String("Zweig: \(sourceTitle)".prefix(40))
        let branch = ChatSession(title: branchTitle, messages: plan.history)
        sessions.insert(branch, at: 0)
        activeSessionId = branch.id
        SessionStore.shared.save(branch)
        AppLog.chat.info("Bearbeitungs-Zweig erstellt: \(branchTitle)")
        return plan.draft
    }

    /// Zweigt einen neuen Chat von der angegebenen Nachricht ab: Die Historie bis einschließlich
    /// dieser Nachricht wird in eine neue Session kopiert, danach läuft der Zweig unabhängig.
    /// (Phase H – bewusst eine echte Kopie statt Message-Referenzen, damit Sessions separat
    /// persistierbar und ohne Risiko löschbar bleiben.)
    func branchFromMessage(id: UUID) {
        guard !isStreaming,
              let sessionIdx = sessions.firstIndex(where: { $0.id == activeSessionId }),
              let srcIdx = sessions[sessionIdx].messages.firstIndex(where: { $0.id == id }) else { return }

        let copied = Array(sessions[sessionIdx].messages.prefix(srcIdx + 1))
        let branchTitle = String("Zweig: \(sessions[sessionIdx].title)".prefix(40))
        let branch = ChatSession(title: branchTitle, messages: copied)
        sessions.insert(branch, at: 0)
        activeSessionId = branch.id
        SessionStore.shared.save(branch)
        AppLog.chat.info("Chat abgezweigt: \(branchTitle)")
    }

    // MARK: - Markdown-Export (für /export und Share-Button)

    /// Baut den Markdown-Export eines Chats. Einzige Quelle für /export UND den Teilen-Button
    /// in der Chat-Leiste (Phase H) – vorher stand der Aufbau nur in exportActiveChat.
    func chatMarkdown(for session: ChatSession) -> String {
        var lines: [String] = ["# \(session.title)", ""]
        for msg in session.messages where msg.role == "user" || msg.role == "assistant" {
            let heading = msg.role == "user" ? "### 🧑 Du" : "### 🎓 Assistent"
            lines.append(heading)
            if !msg.content.isEmpty {
                lines.append(msg.content)
            }
            if msg.imageID != nil { lines.append("_[Screenshot]_") }
            if msg.htmlArtifact != nil { lines.append("_[Interaktive HTML-Ausgabe]_") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Auto-Kompakt (Kontext-Füllstand)

    /// Prüft, ob der aktive Chat sich dem Kontextfenster nähert, und setzt
    /// `shouldSuggestCompaction` für das Angebot in der Chat-Leiste (Phase H). Läuft nach jeder
    /// Antwort, bei Session-Wechsel und nach Dokument-/YouTube-Import (Perf-Audit K3: früher
    /// nur nach Antworten – der Chip veraltete bei Chat-Wechsel und die größten Kontext-
    /// Sprünge (Importe) wurden gar nicht erkannt). Schwellwert und Ein/Aus sind konfigurierbar
    /// (Einstellungen → Erweitert).
    func refreshCompactionHint() {
        guard autoCompactSuggestionsEnabled else {
            shouldSuggestCompaction = false
            return
        }
        shouldSuggestCompaction = (activeContextFillRate ?? 0) > autoCompactThreshold
    }

    /// Grober geschätzter Füllstand (0...1) des aktiven Chats gegen das Kontextfenster.
    /// Nutzt dieselbe Zeichen/4-Heuristik wie das Payload-Budget-Trimmen (trimmedToContextBudget).
    private var activeContextFillRate: Double? {
        guard let profile = activeProfile,
              let idx = sessions.firstIndex(where: { $0.id == activeSessionId }) else { return nil }
        let window = max(profile.contextSizeOverride ?? currentMetrics.contextWindowSize ?? 8192, 2048)
        var chars = 0
        for msg in sessions[idx].messages {
            if msg.role == "document" {
                if let attachment = msg.documentAttachment, attachment.status == .completed {
                    chars += attachment.extractedText.count
                }
            } else if msg.role != "system" {
                chars += msg.content.count + (msg.thinking?.count ?? 0)
            }
        }
        // Double-Division (Perf-Audit L5): Integer-Division kappte bis zu 3 Zeichen je Nachricht.
        return Double(chars) / 4.0 / Double(window)
    }

    // MARK: - YouTube-Transkript-Import

    /// Extrahiert eine YouTube-URL aus einem freien Text (nur wenn der Text praktisch NUR aus
    /// der URL besteht – ein YouTube-Link mitten in einer normalen Frage soll weiter als Frage
    /// durchgehen, nicht den Import triggern).
    static func youTubeURL(in text: String) -> URL? {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: candidate),
              let host = url.host?.lowercased(),
              host.hasSuffix("youtube.com") || host.hasSuffix("youtu.be"),
              YouTubeTranscriptService.videoID(from: url) != nil else { return nil }
        return url
    }

    /// Lädt das Transkript eines Videos und legt es als fertige Dokument-Nachricht im aktiven
    /// Chat ab (Phase H). Der Nutzer kann danach direkt Fragen dazu stellen – das Transkript
    /// fließt über die normale <EXTERNAL_DOCUMENT>-Pipeline in den Modell-Kontext.
    ///
    /// Guards & Config (Perf-Audit M2/M5 + Settings-Audit): Während einer laufenden Antwort wird
    /// der Import abgelehnt (Dokument mitten im Stream kollidiert mit der Antwort); die URL wird
    /// als sichtbare User-Nachricht protokolliert (Titel-/Auto-Labeling-Trigger greifen); das
    /// Transkript wird auf die konfigurierbare Zeichengrenze gekappt; Sprache über Einstellung.
    func importYouTubeTranscript(from url: URL) {
        // Perf-Audit M2: Der Enqueue-Pfad (Folgefrage während des Streamings) führt hier her –
        // ein Import mitten im laufenden Stream würde eine Dokument-Nachricht zwischen die
        // Antwort schieben. Klar abweisen, der Nutzer schickt die URL danach erneut.
        if isStreaming {
            addSystemMessage(text: "YouTube-Import während einer laufenden Antwort nicht möglich – bitte nach Abschluss erneut senden.")
            return
        }
        addSystemMessage(text: "Lade YouTube-Transkript…")
        let preferredLanguage = youtubeSubtitleLanguage
        let charLimit = youtubeTranscriptCharLimit
        Task {
            do {
                var (title, transcript) = try await YouTubeTranscriptService.shared.fetchTranscript(
                    from: url, preferredLanguage: preferredLanguage)
                var wasTrimmed = false
                if transcript.count > charLimit {
                    transcript = String(transcript.prefix(charLimit))
                    wasTrimmed = true
                }
                let finalTitle = title
                let finalTranscript = transcript
                let trimmed = wasTrimmed
                await MainActor.run {
                    guard let idx = sessions.firstIndex(where: { $0.id == activeSessionId }) else { return }
                    // Perf-Audit M5: Die URL als sichtbare User-Nachricht protokollieren – sonst
                    // fehlt der erste User-Turn (Auto-Titel-Trigger greift nie) und die Historie
                    // zeigt nicht, was der Nutzer getan hat.
                    sessions[idx].messages.append(ChatMessage(role: "user", content: url.absoluteString))
                    let attachment = DocumentAttachment(
                        url: URL(fileURLWithPath: "\(finalTitle).txt"),
                        status: .completed,
                        progress: 1.0,
                        extractedText: "--- TRANSKRIPT: \(finalTitle) (\(url.absoluteString)) ---\n\(finalTranscript)"
                    )
                    let docMsg = ChatMessage(role: "document", content: "", documentAttachment: attachment)
                    sessions[idx].messages.append(docMsg)
                    let trimNote = trimmed ? " (auf \(charLimit) Zeichen gekürzt, siehe Erweitert-Einstellungen)" : ""
                    addSystemMessage(text: "Video „\(finalTitle)“ importiert (\(finalTranscript.count / 1000)k Zeichen Transkript\(trimNote)). Frag mich jetzt irgendwas dazu – z.B. „Fasse das Video zusammen“.")
                    // Perf-Audit K3: Import ist der größte mögliche Kontext-Sprung – Hint sofort
                    // aktualisieren, nicht erst nach der nächsten (ggf. schon scheiternden) Antwort.
                    refreshCompactionHint()
                }
            } catch {
                await MainActor.run {
                    addSystemMessage(text: "YouTube-Import fehlgeschlagen: \(error.localizedDescription)")
                }
            }
        }
    }
}
