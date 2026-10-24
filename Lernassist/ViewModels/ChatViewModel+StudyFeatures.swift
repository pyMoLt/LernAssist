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
        let window = max(ModelSettingsRegistry.shared.settings(for: profile.model).contextWindow ?? profile.contextSizeOverride ?? currentMetrics.contextWindowSize ?? Self.fallbackContextWindow, 2048)
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

    // MARK: - Abfragekarten (quiz_card)

    /// Speichert die Antwort auf einer Abfragekarte und schickt sie als Nachricht an das Modell.
    func answerQuizCard(messageId: UUID, optionIndex: Int?, freeText: String?) {
        guard let sIdx = sessions.firstIndex(where: { $0.messages.contains { $0.id == messageId } }),
              let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == messageId }),
              var card = sessions[sIdx].messages[mIdx].quizCard, !card.isAnswered else { return }
        card.selectedIndex = optionIndex
        card.freeTextAnswer = freeText
        sessions[sIdx].messages[mIdx].quizCard = card
        // Falsche Antwort → Fehlerlog (für „Training aus Fehlern“).
        if let optionIndex, let correct = card.correctIndex, optionIndex != correct,
           card.options.indices.contains(optionIndex), card.options.indices.contains(correct) {
            recordMistake(MistakeEntry(kind: .quiz, sessionId: sessions[sIdx].id, subject: sessions[sIdx].subject,
                                       question: card.question, givenAnswer: card.options[optionIndex],
                                       correctAnswer: card.options[correct], explanation: card.explanation))
        }
        let text = Self.quizAnswerText(card: card, optionIndex: optionIndex, freeText: freeText)
        if isStreaming { enqueueMessage(text: text) } else { sendMessage(text: text) }
    }

    static func quizAnswerText(card: QuizCard, optionIndex: Int?, freeText: String?) -> String {
        if let optionIndex, card.options.indices.contains(optionIndex) {
            let letter = String(UnicodeScalar(65 + optionIndex).map(Character.init) ?? "?")
            var text = "Meine Antwort auf „\(card.question)“: \(letter)) \(card.options[optionIndex])"
            if let correct = card.correctIndex {
                text += optionIndex == correct ? " (richtig)" : " (falsch)"
            }
            return text
        }
        return "Meine Antwort auf „\(card.question)“: \(freeText ?? "")"
    }

    // MARK: - Anklickbare Belege [W#]

    /// Quellen-URLs der [W#]-Belege, die eine Antwort zitieren kann. Die Nummern sind im ganzen Chat
    /// eindeutig (`renumberCitations`), daher reicht eine Suche über alle früheren Websuchen. Bei
    /// älteren Chats mit Nummern pro Suche gewinnt die nächstgelegene Suche.
    func citationLinks(for messageID: UUID) -> [String: String] {
        guard let session = sessions.first(where: { $0.messages.contains { $0.id == messageID } }),
              let index = session.messages.firstIndex(where: { $0.id == messageID }) else { return [:] }
        var links: [String: String] = [:]
        for msg in session.messages[...index].reversed() {
            for call in msg.toolCalls ?? [] where call.name == "web_search" {
                for source in ToolCallPresentation(call: call).sources where links[source.number] == nil && !source.url.isEmpty {
                    links[source.number] = source.url
                }
            }
        }
        return links
    }

    /// Fortlaufende Belegnummern über den ganzen Chat: Neue Websuchen zählen dort weiter, wo die
    /// bisherigen aufgehört haben, und dieselbe Seite behält ihre Nummer. Parallele Suchen einer
    /// Runde werden in Aufruf-Reihenfolge nummeriert. Läuft einmal, bevor die Ergebnisse ans Modell
    /// gehen – danach ändern sie sich nie mehr (Prefix-Cache).
    static func renumberCitations(in calls: [ToolCallInfo], after earlier: [ToolCallInfo]) -> [ToolCallInfo] {
        var numberByKey: [String: Int] = [:]
        var highest = 0
        for call in earlier where call.name == "web_search" {
            for source in ToolCallPresentation(call: call).sources {
                guard let number = Int(source.number.dropFirst()) else { continue }
                highest = max(highest, number)
                if !source.url.isEmpty, numberByKey[SearchHit.normalizedKey(source.url)] == nil {
                    numberByKey[SearchHit.normalizedKey(source.url)] = number
                }
            }
        }
        var result = calls
        for index in result.indices where result[index].name == "web_search" {
            guard let text = result[index].result else { continue }
            var mapping: [String: Int] = [:]
            for source in ToolCallPresentation(call: result[index]).sources where mapping[source.number] == nil {
                let key = SearchHit.normalizedKey(source.url)
                if !source.url.isEmpty, let existing = numberByKey[key] {
                    mapping[source.number] = existing
                } else {
                    highest += 1
                    mapping[source.number] = highest
                    if !source.url.isEmpty { numberByKey[key] = highest }
                }
            }
            guard !mapping.isEmpty else { continue }
            result[index].result = text.components(separatedBy: "\n").map { line in
                guard line.hasPrefix("[W"), let close = line.firstIndex(of: "]"),
                      let number = mapping[String(line[line.index(after: line.startIndex)..<close])] else { return line }
                return "[W\(number)]" + line[line.index(after: close)...]
            }.joined(separator: "\n")
        }
        return renumberImages(in: result, after: earlier)
    }

    /// Wie bei den Belegen: Abbildungen [B#] fortlaufend im ganzen Chat, gleiches Bild = gleiche Nummer.
    static func renumberImages(in calls: [ToolCallInfo], after earlier: [ToolCallInfo]) -> [ToolCallInfo] {
        var numberByKey: [String: Int] = [:]
        var highest = 0
        for ref in earlier.flatMap({ $0.researchImages ?? [] }) {
            highest = max(highest, ref.number)
            numberByKey[SearchHit.normalizedKey(ref.sourceURL)] = numberByKey[SearchHit.normalizedKey(ref.sourceURL)] ?? ref.number
        }
        var result = calls
        for index in result.indices {
            guard var refs = result[index].researchImages, !refs.isEmpty else { continue }
            var mapping: [Int: Int] = [:]
            for position in refs.indices {
                let key = SearchHit.normalizedKey(refs[position].sourceURL)
                let number: Int
                if let existing = numberByKey[key] {
                    number = existing
                } else {
                    highest += 1
                    number = highest
                    numberByKey[key] = number
                }
                mapping[refs[position].number] = number
                refs[position].number = number
            }
            result[index].researchImages = refs
            if let text = result[index].result {
                result[index].result = text.components(separatedBy: "\n").map { line in
                    guard line.hasPrefix("[B"), let close = line.firstIndex(of: "]"),
                          let old = Int(line[line.index(line.startIndex, offsetBy: 2)..<close]),
                          let number = mapping[old] else { return line }
                    return "[B\(number)]" + line[line.index(after: close)...]
                }.joined(separator: "\n")
            }
        }
        return result
    }

    /// Abbildungen, die eine Antwort mit [B#] zeigen kann (im ganzen Chat eindeutig).
    func researchImages(for messageID: UUID) -> [Int: ResearchImageRef] {
        guard let session = sessions.first(where: { $0.messages.contains { $0.id == messageID } }),
              let index = session.messages.firstIndex(where: { $0.id == messageID }) else { return [:] }
        var images: [Int: ResearchImageRef] = [:]
        for msg in session.messages[...index].reversed() {
            for call in msg.toolCalls ?? [] {
                for ref in call.researchImages ?? [] where images[ref.number] == nil { images[ref.number] = ref }
            }
        }
        return images
    }

    /// Selbstgenerierte Python-Plots dieses Antwort-Turns (`pageURL.isEmpty`), für die Hauptantwort
    /// des Turns. Vergisst das Modell `[B#]` im Text zu setzen, zeigt `embedResearchImages` sie
    /// automatisch oben an, damit kein berechneter Plot verloren geht.
    func turnPlots(for messageID: UUID) -> [ResearchImageRef] {
        guard let session = sessions.first(where: { $0.messages.contains { $0.id == messageID } }),
              let index = session.messages.firstIndex(where: { $0.id == messageID }),
              session.messages[index].role == "assistant" else { return [] }
        var start = index
        while start > 0 && session.messages[start - 1].role == "assistant" { start -= 1 }
        var end = index
        while end + 1 < session.messages.count && session.messages[end + 1].role == "assistant" { end += 1 }
        let turnMessages = Array(session.messages[start...end])
        let primaryID = turnMessages.last(where: WorkStep.hasAnswerText)?.id ?? turnMessages.last?.id
        guard primaryID == messageID else { return [] }
        let otherContent = turnMessages.filter { $0.id != messageID }.map(\.content).joined(separator: "\n")
        var plots: [ResearchImageRef] = []
        var seen = Set<Int>()
        for msg in turnMessages {
            for call in msg.toolCalls ?? [] {
                for ref in call.researchImages ?? [] where ref.pageURL.isEmpty && seen.insert(ref.number).inserted {
                    if !otherContent.contains("[B\(ref.number)]") {
                        plots.append(ref)
                    }
                }
            }
        }
        return plots
    }

    /// Setzt Abbildungen ein: Eine Zeile mit [B3] (allein oder mit nachfolgender Bildunterschrift)
    /// wird zum Bild; [B3] mitten im Satz wird zum Link bzw. Verweis. Selbstgenerierte Plots des
    /// aktuellen Turns, die das Modell nicht mit [B#] eingebunden hat, erscheinen automatisch oben.
    static func embedResearchImages(in markdown: String,
                                    images: [Int: ResearchImageRef],
                                    turnPlots: [ResearchImageRef] = []) -> String {
        guard !images.isEmpty || !turnPlots.isEmpty else { return markdown }
        var embeddedNumbers = Set<Int>()
        var lines: [String] = []
        if !images.isEmpty, markdown.contains("[B") {
            let lineRegex = try? NSRegularExpression(pattern: #"^[*_\s]*\[B(\d+)\][*_.:—–\-\s]*(.*)$"#)
            var inCode = false
            for line in markdown.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") { inCode.toggle() }
                guard !inCode else { lines.append(line); continue }
                let ns = trimmed as NSString
                if let match = lineRegex?.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
                   let number = Int(ns.substring(with: match.range(at: 1))),
                   let ref = images[number] {
                    embeddedNumbers.insert(number)
                    let trailing = ns.substring(with: match.range(at: 2))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "*_ ").union(.whitespaces))
                    let rawCaption = trailing.isEmpty ? ref.caption : trailing
                    let caption = rawCaption.replacingOccurrences(of: "]", with: ")").replacingOccurrences(of: "[", with: "(")
                    lines.append("![\(caption)](lernassist-image://\(ref.imageID.uuidString))")
                    if !ref.pageURL.isEmpty {
                        lines.append("")
                        lines.append("*\(caption)* · [Quelle: \(ref.domain)](\(ref.pageURL))")
                    } else if !trailing.isEmpty {
                        lines.append("")
                        lines.append("*\(trailing)*")
                    }
                    continue
                }
                var converted = line
                for (number, ref) in images {
                    let replacement = ref.pageURL.isEmpty ? "(Abb. B\(number))" : "[Abb. B\(number)](\(ref.pageURL))"
                    converted = converted.replacingOccurrences(of: "[B\(number)]", with: replacement)
                }
                lines.append(converted)
            }
        } else {
            lines = [markdown]
        }
        let body = lines.joined(separator: "\n")
        let unreferencedPlots = turnPlots.filter { !embeddedNumbers.contains($0.number) }
        guard !unreferencedPlots.isEmpty else { return body }
        let prefix = unreferencedPlots.map { plot in
            let caption = plot.caption.replacingOccurrences(of: "]", with: ")").replacingOccurrences(of: "[", with: "(")
            return "![\(caption)](lernassist-image://\(plot.imageID.uuidString))"
        }.joined(separator: "\n\n")
        return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? prefix : prefix + "\n\n" + body
    }

    /// Ersetzt [W1] bzw. [W1, W3] durch Markdown-Links auf die Quellen.
    static func linkCitations(in markdown: String, links: [String: String]) -> String {
        guard !links.isEmpty, markdown.contains("[W") else { return markdown }
        guard let regex = try? NSRegularExpression(pattern: #"\[(W\d+(?:\s*[,;]\s*W\d+)*)\](?!\()"#) else { return markdown }
        let ns = markdown as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let inner = ns.substring(with: match.range(at: 1))
            let parts = inner.components(separatedBy: CharacterSet(charactersIn: ",;")).map { $0.trimmingCharacters(in: .whitespaces) }
            result += parts.map { part in
                if let url = links[part] { return "[\(part)](\(url))" }
                return "[\(part)]"
            }.joined(separator: " ")
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}

// MARK: - Interaktive Ausgaben

extension ChatViewModel {
    /// Klappt eine interaktive Ausgabe ein oder aus (bleibt im Chat gespeichert). Die Nachricht
    /// geht nicht an das Modell – der Verlauf und damit der Cache bleiben unverändert.
    func toggleArtifactCollapsed(messageId: UUID) {
        guard let sIdx = sessions.firstIndex(where: { $0.messages.contains { $0.id == messageId } }),
              let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == messageId }) else { return }
        let collapsed = !(sessions[sIdx].messages[mIdx].artifactCollapsed ?? false)
        sessions[sIdx].messages[mIdx].artifactCollapsed = collapsed ? true : nil
        SessionStore.shared.save(sessions[sIdx])
    }

    /// Datei der Ausgabe im Chat-Ordner (wird bei Bedarf geschrieben, auch für ältere Chats).
    func artifactFileURL(for message: ChatMessage) -> URL? {
        guard let html = message.htmlArtifact,
              let session = sessions.first(where: { $0.messages.contains { $0.id == message.id } }) else { return nil }
        return HTMLArtifactFiles.save(html, messageID: message.id, sessionID: session.id.uuidString)
    }

    /// Lässt ein Diagramm, das auch nach der automatischen Reparatur nicht zeichnet, vom Modell
    /// im Hintergrund korrigieren. Das Ergebnis gilt nur für die Anzeige (`displayFixes`).
    func repairDiagram(messageId: UUID, source: String, error: String) {
        Task { @MainActor in
            let prompt = """
            Das folgende Mermaid-Diagramm lässt sich nicht zeichnen. Fehlermeldung: \(error.isEmpty ? "unbekannt" : error)

            Korrigiere nur die Syntax und behalte Inhalt und Aufbau. Antworte ausschließlich mit dem korrigierten \
            Mermaid-Code, ohne Erklärung und ohne ```-Zäune.

            \(source)
            """
            guard var fixed = await sendInvisiblePrompt(prompt, context: [], maxTokens: 4_000) else { return }
            fixed = fixed.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^\s*```\s*(mermaid)?\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*```\s*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fixed.isEmpty,
                  let sIdx = sessions.firstIndex(where: { $0.messages.contains { $0.id == messageId } }),
                  let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == messageId }) else { return }
            var fixes = sessions[sIdx].messages[mIdx].displayFixes ?? [:]
            fixes[source] = fixed + (source.hasSuffix("\n") ? "\n" : "")
            sessions[sIdx].messages[mIdx].displayFixes = fixes
            SessionStore.shared.save(sessions[sIdx])
        }
    }

    /// Inhalt für die Anzeige: reparierte Diagramme eingesetzt.
    nonisolated static func applyingDisplayFixes(_ content: String, _ fixes: [String: String]?) -> String {
        guard let fixes, !fixes.isEmpty else { return content }
        var result = content
        for (source, fixed) in fixes where !source.isEmpty {
            result = result.replacingOccurrences(of: source, with: fixed)
        }
        return result
    }
}
