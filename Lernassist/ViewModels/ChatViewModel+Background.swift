import Foundation
import SwiftUI
import AppKit
import Combine
import os

// Unsichtbare Prompts und Hintergrund-Jobs (Titel, Bildbeschreibung, Verifizieren).
extension ChatViewModel {
    // MARK: - Invisible Prompts für Hintergrund-Generierung (Quiz/Flashcards/Verify)
    
    /// Sendet einen Prompt ohne ihn in der Session zu speichern und gibt die gesammelte Antwort zurück.
    /// Bettet Bilder aus `context` (z.B. Screenshots im Chatverlauf) als Vision-Content ein, statt sie
    /// stillschweigend zu verwerfen – sonst "sieht" z.B. das Quiz/die Karteikarten nichts von den
    /// Screenshots, obwohl der Chat-Kontext primär aus Bildern bestehen kann (Kernfunktion der App).
    /// - Parameter useBackgroundJobModel: true für reine Hintergrund-Jobs (Titel, Zusammenfassung) –
    ///   nutzt dann `profile.backgroundJobModel` (falls gesetzt) statt des vollen Chat-Modells und
    ///   wendet bei aktivem `disableThinkingForBackgroundJobs` die Best-effort-"No Thinking"-
    ///   Modifikatoren an. Bewusst NICHT für Quiz/Karteikarten-Generierung genutzt, da dort die
    ///   inhaltliche Qualität (korrekte Fragen/Antworten) wichtiger ist als Geschwindigkeit.
    /// Richtet die Python-Umgebung ein (bzw. neu) und meldet den Fortschritt an die UI.
    func setupPythonEnvironment(force: Bool = false) {
        Task.detached(priority: .utility) { [weak self] in
            let viewModel = self
            let report: @Sendable (PythonEnvironmentStatus) -> Void = { status in
                Task { @MainActor in viewModel?.pythonEnvironmentStatus = status }
            }
            if force {
                await PythonEnvironmentInstaller.shared.ensureInstalled(force: true, onStatus: report)
            } else {
                await CodingEnvironment.shared.setupEnvironmentIfNeeded(onStatus: report)
            }
        }
    }

    func sendInvisiblePrompt(_ prompt: String, context: [ChatMessage],
                             imageBase64: String? = nil,
                             useBackgroundJobModel: Bool = false,
                             maxTokens: Int? = nil,
                             jsonSchema: (name: String, schema: [String: Any])? = nil) async -> String? {
        guard let profile = activeProfile else {
            AppLog.chat.error("sendInvisiblePrompt: kein Endpunkt konfiguriert")
            return nil
        }

        let applyNoThink = useBackgroundJobModel && disableThinkingForBackgroundJobs
        let effectivePrompt = applyNoThink ? prompt + "\n/no_think" : prompt

        var messages: [[String: Any]] = context.map { msg in
            if let b64 = Self.imagePayloadBase64(for: msg) {
                return EndpointManager.userImageMessage(text: msg.content, base64: b64, provider: profile.provider)
            }
            return ["role": msg.role, "content": msg.content]
        }
        if let b64 = imageBase64 {
            messages.append(EndpointManager.userImageMessage(text: effectivePrompt, base64: b64, provider: profile.provider))
        } else {
            messages.append(["role": "user", "content": effectivePrompt])
        }

        let builder = ChatRequestBuilder(profile: profile)
        let purpose = ChatRequestBuilder.Purpose.background(useBackgroundModel: useBackgroundJobModel,
                                                            disableThinking: applyNoThink)
        let request: URLRequest
        do {
            request = try builder.urlRequest(
                payload: builder.payload(messages: messages, purpose: purpose, stream: false, maxTokens: maxTokens,
                                         jsonSchema: profile.provider == .ollama ? nil : jsonSchema),
                stream: false)
        } catch {
            AppLog.chat.error("sendInvisiblePrompt: Request-Aufbau fehlgeschlagen")
            return nil
        }

        // LM Studio: Ein EIGENES Hintergrundmodell sicherstellen und danach wieder freigeben.
        // Ist kein Hintergrundmodell gesetzt, läuft der Job auf dem bereits geladenen
        // Hauptmodell – kein zweites Laden, kein versehentliches Entladen danach.
        let manager = LMStudioModelManager.shared
        var lmsInstanceId: String?
        let hasSeparateBackgroundModel = builder.model(for: purpose) != profile.model
        if hasSeparateBackgroundModel && manager.isLMStudioLocal(profile: profile) {
            let lmsModelId = manager.effectiveLMStudioModelId(profile: profile, useBackground: true)
            lmsInstanceId = await manager.acquire(modelId: lmsModelId, baseURL: profile.baseURL, apiKey: profile.apiKey)
        }
        defer {
            if let instanceId = lmsInstanceId {
                Task {
                    let lmsModelId = manager.effectiveLMStudioModelId(profile: profile, useBackground: true)
                    await manager.release(instanceId: instanceId, modelId: lmsModelId, baseURL: profile.baseURL, apiKey: profile.apiKey)
                }
            }
        }

        do {
            return try await LLMClient.complete(request)
        } catch {
            // Fehler werden nie zur „Antwort“ (früher landete ein Fehlertext z. B. als Chat-Titel).
            AppLog.chat.error("sendInvisiblePrompt: \(error.localizedDescription) (\(profile.name))")
            return nil
        }
    }

    /// Zwingt das Modell, seine letzte Antwort aktiv per Websuche zu überprüfen.
    /// Aufrufbar über den "Verifizieren"-Button an einer Nachricht oder den `/verify`-Befehl.
    func verifyLastResponse() {
        guard let session = activeSession,
              session.messages.last(where: { $0.role == "assistant" && !$0.content.isEmpty }) != nil
        else {
            addSystemMessage(text: "Nichts zu verifizieren – es gibt noch keine Antwort in diesem Chat.")
            return
        }

        let notice = searchEnabled ? "" :
            "\n\n(Hinweis: Die Websuche ist aktuell deaktiviert – aktiviere sie in den Einstellungen für eine echte Verifikation.)"
        sendMessage(text: """
            Verifiziere deine letzte Antwort aktiv per Websuche. Gehe so vor:
            1. Identifiziere die zentralen, überprüfbaren Fakten-Aussagen in deiner letzten Antwort.
            2. Suche gezielt nach jeder Aussage, um sie zu bestätigen oder zu widerlegen.
            3. Gib für jede Aussage an: ✅ Bestätigt / ⚠️ Teilweise / ❌ Widerlegt / ❓ Nicht auffindbar – jeweils mit Quelle.
            4. Fasse am Ende zusammen, ob deine vorherige Antwort insgesamt verlässlich war.\(notice)
            """)
    }

    // MARK: - Hintergrund-Jobs (Phase 7C)
    // Laufen erst NACH einer vollständig abgeschlossenen Antwort-Runde (kein Streaming mehr aktiv),
    // damit sie nicht um Netzwerk-/Modell-Kapazität mit der eigentlichen Konversation konkurrieren.
    // Status wird über `backgroundJobStatus` in der MetricsBar sichtbar gemacht.

    /// Beendet die aktuelle Antwort-Runde mit einer sichtbaren Fehlermeldung an der Ziel-Bubble,
    /// ohne die nächste Queue-Nachricht automatisch nachzufeuern (Audit M1/M4): Nach fehlge-
    /// schlagenem Runden-Start (ungültige URL, Payload-Fehler, gelöschte Session/Nachricht) darf
    /// keine Folgenachricht blind gegen denselben kaputten Endpunkt gesendet werden.
    func failCurrentExchange(sessionId: UUID, targetMsgId: UUID, message: String) {
        if let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
           let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == targetMsgId }) {
            sessions[sIdx].messages[mIdx].errorMessage = message
        }
        suppressQueueAutoAdvance = true
        isStreaming = false
        suppressQueueAutoAdvance = false
    }

    /// Beendet eine Antwort-Runde und stößt ggf. Hintergrund-Jobs an. Einziger Ort, an dem
    /// `isStreaming` nach erfolgreichem Abschluss (nicht Fehler/Abbruch) zurückgesetzt wird.
    func finishExchange(sessionId: UUID) {
        isStreaming = false
        runBackgroundJobsIfNeeded(sessionId: sessionId)
        refreshCompactionHint() // Auto-Kompakt-Angebot prüfen (Phase H)
    }

    func runBackgroundJobsIfNeeded(sessionId: UUID) {
        guard let sessionIdx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        let session = sessions[sessionIdx]

        if autoLabelingEnabled {
            // WICHTIG: `sendMessage()` setzt bereits synchron einen (groben) Titel aus den ersten
            // 40 Zeichen der User-Nachricht, BEVOR diese Methode je läuft – ein "sieht noch
            // unbetitelt aus"-Check (== "Neuer Chat") würde daher nach der allerersten Nachricht
            // NIE MEHR zutreffen und das Auto-Labeling faktisch permanent deaktivieren (beobachteter
            // Bug: "Hintergrundlabeling funktioniert nicht"). Stattdessen: auslösen, solange der
            // Titel noch der rohe Nachricht-Präfix (oder "Neuer Chat") ist – das deckt auch den
            // Fall ab, dass die erste Runde mehrere Assistant-Textnachrichten enthielt (Tool-Runde
            // mit Zwischentext), bei dem ein exakter `count == 1`-Trigger nie mehr griff.
            let stillDefaultTitle: Bool
            if session.title == "Neuer Chat" {
                stillDefaultTitle = true
            } else if let firstUser = session.messages.first(where: { $0.role == "user" }) {
                // Slash-Befehle setzen den Titel aus der kurzen Anzeige (displayText), nicht aus dem Prompt.
                stillDefaultTitle = session.title == String((firstUser.displayText ?? firstUser.content).prefix(40))
            } else {
                stillDefaultTitle = false
            }
            let userTurns = session.messages.filter { $0.role == "user" }.count
            // Nach N Fragen einmal nachschärfen: Der Fokus eines Chats wandert oft.
            let needsRefinement = !stillDefaultTitle && session.titleRefined != true && userTurns >= max(2, titleRefinementTurns)
            if (stillDefaultTitle || needsRefinement), !titlingInProgress.contains(sessionId) {
                let titleBeforeGeneration = session.title
                let refine = needsRefinement
                Task {
                    // Siehe waitUntilIdle(): eine gequeute Folgenachricht kann isStreaming
                    // zwischen dem Aufruf hier und der eigentlichen Ausführung bereits wieder auf
                    // true gesetzt haben (siehe isStreaming-didSet) – dann NICHT parallel zur neu
                    // gestarteten Konversation um Modell-/Netzwerkkapazität konkurrieren.
                    await self.waitUntilIdle()
                    await self.generateTitle(sessionId: sessionId, previousTitle: titleBeforeGeneration, refine: refine)
                }
            }
        }

        if autoImageToTextEnabled,
           let msg = session.messages.last(where: { $0.role == "user" && $0.imageBase64 != nil && $0.imageDescription == nil }),
           !describingImages.contains(msg.id) {
            let base64 = msg.imageBase64!
            let msgId = msg.id
            Task {
                await self.waitUntilIdle()
                await self.describeImage(sessionId: sessionId, messageId: msgId, base64: base64)
            }
        }
    }

    /// Wartet, bis `isStreaming` wieder `false` ist. Schützt die beiden Hintergrund-Jobs oben davor,
    /// mit einer Konversation um Modell-/Netzwerkkapazität zu konkurrieren, die durch eine gequeute
    /// Folgenachricht (siehe `isStreaming`-didSet) unmittelbar nach Abschluss der vorigen Antwort
    /// bereits wieder neu gestartet wurde, bevor `runBackgroundJobsIfNeeded` überhaupt lief. Ohne
    /// dieses Warten lief z.B. bei LM Studio der Titel-Job UND die nachgereichte Nachricht
    /// gleichzeitig gegen dasselbe Modell – die nachgereichte Antwort kam dabei nicht sauber an.
    /// Zeitlich begrenzt (10 min) und abbruchfähig, damit ein jemals hängendes `isStreaming`
    /// (historischer Bug beim Coding-Tool-Timeout) nicht dauerhaft alle Titel-/Bild-Jobs blockiert.
    func waitUntilIdle() async {
        let idleTimeout = Date().addingTimeInterval(600)
        while isStreaming && Date() < idleTimeout && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Alle bisher vergebenen Fächer (für einheitliche Etiketten).
    var knownSubjects: [String] {
        let all = (sessions + archivedSessions).compactMap(\.subject).filter { !$0.isEmpty }
        var seen = Set<String>()
        return all.filter { seen.insert($0.lowercased()).inserted }.sorted()
    }

    /// Auto-Labeling: Titel (2–4 Wörter) und Fach-Etikett in einem Aufruf. Nach der ersten Antwort
    /// und einmal nach der dritten Frage (`refine`), falls sich der Schwerpunkt verschoben hat.
    func generateTitle(sessionId: UUID, previousTitle: String, refine: Bool = false) async {
        titlingInProgress.insert(sessionId)
        defer { titlingInProgress.remove(sessionId) }

        guard let sessionIdx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        let dialog = sessions[sessionIdx].messages.filter { $0.role == "user" || $0.role == "assistant" }
        // Beim Nachschärfen den ganzen bisherigen Verlauf (gekürzt), sonst den Anfang.
        let context = refine ? Array(dialog.suffix(10)) : Array(dialog.prefix(6))
        guard !context.isEmpty else { return }

        backgroundJobStatus = "Generiere Titel..."
        defer { if backgroundJobStatus == "Generiere Titel..." { backgroundJobStatus = nil } }

        let subjects = knownSubjects
        let subjectHint = subjects.isEmpty ? "" : " Bereits verwendete Fächer (bevorzugt wiederverwenden, wenn passend): \(subjects.prefix(30).joined(separator: ", "))."
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["title": ["type": "string"], "subject": ["type": "string"]],
            "required": ["title", "subject"], "additionalProperties": false]
        let raw = await sendInvisiblePrompt(
            "Gib diesem Gespräch einen Titel aus 2–4 Wörtern, der das konkrete Fachthema nennt " +
            "(z. B. „Michaelis-Menten-Kinetik“, „Gerinnungskaskade Ablauf“, „Dijkstra-Algorithmus“). " +
            "Keine Füllwörter wie „Erklärung“, „Frage zu“ oder „Hilfe bei“, keine Anführungszeichen, keine Emojis. " +
            "Ordne es außerdem einem allgemeinen Fach zu (1–2 Wörter, z. B. „Physiologie“, „Biochemie“, „Algorithmen“, „Analysis“)." +
            subjectHint +
            (refine ? " Berücksichtige den gesamten bisherigen Verlauf, nicht nur den Anfang." : "") +
            " Antworte nur mit JSON: {\"title\": \"…\", \"subject\": \"…\"}",
            context: context,
            useBackgroundJobModel: true,
            jsonSchema: ("chat_title", schema)
        )
        // Fehler (Netzwerk/HTTP) werden nicht als Titel übernommen.
        guard let raw, !raw.isEmpty, let parsed = Self.parseTitleAndSubject(raw) else { return }

        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        // Nur überschreiben, wenn der Titel zwischenzeitlich nicht (z. B. vom Nutzer) geändert wurde.
        guard sessions[idx].title == previousTitle else { return }
        if !parsed.title.isEmpty { sessions[idx].title = parsed.title }
        if let subject = parsed.subject, !subject.isEmpty, sessions[idx].subjectSetByUser != true {
            // Schreibweise eines bekannten Fachs übernehmen („physiologie“ → „Physiologie“).
            sessions[idx].subject = subjects.first { $0.lowercased() == subject.lowercased() } ?? subject
        }
        if refine || sessions[idx].messages.filter({ $0.role == "user" }).count >= 3 {
            sessions[idx].titleRefined = true
        }
    }

    /// Liest {"title", "subject"}; fällt auf reinen Text (nur Titel) zurück.
    nonisolated static func parseTitleAndSubject(_ raw: String) -> (title: String, subject: String?)? {
        func clean(_ text: String) -> String {
            let line = text.components(separatedBy: .newlines).first ?? text
            return String(line.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'„“”.·")).prefix(40))
        }
        var text = raw.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            text = String(text[start...end])
        }
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let title = clean(object["title"] as? String ?? "")
            let subject = (object["subject"] as? String).map { String(clean($0).prefix(30)) }
            return title.isEmpty && (subject ?? "").isEmpty ? nil : (title, subject)
        }
        let title = clean(raw)
        return title.isEmpty || title.count > 60 ? nil : (title, nil)
    }

    /// Bild-zu-Text: beschreibt einen angehängten Screenshot im Hintergrund, damit ältere
    /// Bilder im Verlauf als günstiger Text statt als erneut mitgeschicktes Rohbild zur
    /// Verfügung stehen (siehe `apiMessages`).
    func describeImage(sessionId: UUID, messageId: UUID, base64: String) async {
        // Doppel-Ausführungsschutz (Audit M11): sendMessage und runBackgroundJobsIfNeeded
        // stößen beide Task-Instanzen an (je hinter waitUntilIdle) – ohne Guard würde dasselbe
        // Bild vom ersten Task beschrieben und vom zweiten nochmal (zweiter Modell-Roundtrip).
        guard !describingImages.contains(messageId) else { return }
        if let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
           let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == messageId }),
           sessions[sIdx].messages[mIdx].imageDescription != nil {
            return // bereits beschrieben
        }
        describingImages.insert(messageId)
        defer { describingImages.remove(messageId) }

        backgroundJobStatus = "Beschreibe Bild..."
        defer { if backgroundJobStatus == "Beschreibe Bild..." { backgroundJobStatus = nil } }

        let description = await sendInvisiblePrompt(
            "Beschreibe kurz und präzise (2-4 Sätze), was auf diesem Screenshot zu sehen ist. " +
            "Antworte NUR mit der Beschreibung, ohne Einleitung.",
            context: [],
            imageBase64: base64,
            useBackgroundJobModel: true
        )
        // Bei Fehlern bleibt imageDescription nil – der Freeze-Mechanismus snapshotet dann
        // nil und die Nachricht wird ohne Bildkontext eingefroren (weiterhin korrekt).
        guard let description else { return }

        guard let sessionIdx = sessions.firstIndex(where: { $0.id == sessionId }),
              let msgIdx = sessions[sessionIdx].messages.firstIndex(where: { $0.id == messageId })
        else { return }
        sessions[sessionIdx].messages[msgIdx].imageDescription = description
    }
}
