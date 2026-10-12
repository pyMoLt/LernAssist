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
                stillDefaultTitle = session.title == String(firstUser.content.prefix(40))
            } else {
                stillDefaultTitle = false
            }
            if stillDefaultTitle, !titlingInProgress.contains(sessionId) {
                let titleBeforeGeneration = session.title
                Task {
                    // Siehe waitUntilIdle(): eine gequeute Folgenachricht kann isStreaming
                    // zwischen dem Aufruf hier und der eigentlichen Ausführung bereits wieder auf
                    // true gesetzt haben (siehe isStreaming-didSet) – dann NICHT parallel zur neu
                    // gestarteten Konversation um Modell-/Netzwerkkapazität konkurrieren.
                    await self.waitUntilIdle()
                    await self.generateTitle(sessionId: sessionId, previousTitle: titleBeforeGeneration)
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

    /// Auto-Labeling: generiert nach der ersten vollständigen Antwort einen kurzen, passenden
    /// Titel für den Chat (löst die pauschale "erste 40 Zeichen"-Titelvergabe ab).
    func generateTitle(sessionId: UUID, previousTitle: String) async {
        titlingInProgress.insert(sessionId)
        defer { titlingInProgress.remove(sessionId) }

        guard let sessionIdx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        let context = Array(sessions[sessionIdx].messages.filter { $0.role == "user" || $0.role == "assistant" }.prefix(6))
        guard !context.isEmpty else { return }

        backgroundJobStatus = "Generiere Titel..."
        defer { if backgroundJobStatus == "Generiere Titel..." { backgroundJobStatus = nil } }

        let title = await sendInvisiblePrompt(
            "Fasse das bisherige Gespräch in einem sehr kurzen, prägnanten Titel zusammen " +
            "(max. 6 Wörter, keine Anführungszeichen, keine Emojis, kein Punkt am Ende). Antworte NUR mit dem Titel.",
            context: context,
            useBackgroundJobModel: true
        )
        // Fehler (Netzwerk/HTTP) werden nicht als Titel übernommen – früher landete z.B.
        // "Netzwerkfehler: ..." als Chat-Titel in der Sidebar.
        guard let title, !title.isEmpty else { return }

        let cleaned = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'„“”.·"))
        guard !cleaned.isEmpty, cleaned.count < 200 else { return }

        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        // Nur überschreiben, wenn sich der Titel zwischenzeitlich nicht schon geändert hat
        // (z.B. weil der Nutzer manuell umbenannt hat, während der Job lief) – exakter Vergleich
        // mit dem beim Auslösen erfassten Titel statt einer "sieht unbetitelt aus"-Heuristik,
        // die nach der ersten Nachricht nie mehr zutrifft (s. Kommentar in runBackgroundJobsIfNeeded).
        guard sessions[idx].title == previousTitle else { return }
        sessions[idx].title = String(cleaned.prefix(50))
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
