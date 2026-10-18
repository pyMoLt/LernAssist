import Foundation
import SwiftUI
import AppKit
import Combine
import os

// Tool-Loop nach dem Stream: Tool-Calls ausführen, Ergebnisse einspeisen, Registry-Sync.
extension ChatViewModel {
    // MARK: - Nach Streaming: Tool-Calls ausführen oder fertig

    /// Hinweis an das Modell im letzten Tool-Ergebnis der letzten erlaubten Runde. Steht im
    /// Tool-Ergebnis statt im System-Prompt: Tools und System-Prompt bleiben über den ganzen
    /// Turn unverändert, sonst verwirft der Server seinen Prefix-Cache ab Token 0.
    static let toolFinalRoundNotice = "[Hinweis der App: Das war die letzte erlaubte Tool-Runde. Rufe keine weiteren Tools auf. Beantworte die Frage jetzt mit den bisherigen Ergebnissen. Reichen sie nicht aus, sag ehrlich, welche Informationen fehlen oder unsicher sind.]"
    /// Ergebnis für Aufrufe, die das Modell trotz des Hinweises noch stellt.
    static let toolLimitNotExecutedMessage = "Nicht ausgeführt: Das Tool-Limit ist erreicht. Antworte jetzt ohne weitere Tools mit den bisherigen Ergebnissen und sag ehrlich, was fehlt oder unsicher ist."
    static let toolLimitFallbackAnswer = "Ich konnte nach mehreren Tool-Aufrufen keine brauchbare Antwort finden. Versuch's gerne mit einer präziseren Frage oder einer anderen Quelle."

    static func toolInvocationSignature(_ call: ToolCallInfo) -> String {
        "\(call.name)\u{001F}\(call.arguments)"
    }

    func handleFinished(profile: EndpointProfile, sessionIdx: Int, assistantMsgId: UUID,
                        sessionId: UUID, prevMessages: [[String: Any]]) {
        let configuredMaxToolRounds = min(max(maxToolRounds, 1), 25)

        guard sessions.indices.contains(sessionIdx),
              let mIdx = sessions[sessionIdx].messages.firstIndex(where: { $0.id == assistantMsgId }) else {
            finishExchange(sessionId: sessionId); return
        }

        // --- Inline-Fallback-Parser ---
        // Für Modelle/Server ohne natives Function-Calling. Das Thinking bleibt sichtbar, nur
        // das Tool-Markerfragment wird entfernt.
        // Härtung (Audit 2026-10-12, Alt-H4): Hat der Server echte tool_calls geliefert, werden
        // eingebettete Marker ignoriert – sie stammen dann eher aus zitierten Webinhalten als aus
        // einer Absicht des Modells. Aus dem Thinking werden Calls nur übernommen, wenn die
        // sichtbare Antwort leer ist (das Modell hat also wirklich nur „aufgerufen“).
        var inlineCalls: [ToolCallParser.ParsedCall] = []
        let hasNativeCalls = !(sessions[sessionIdx].messages[mIdx].toolCalls ?? []).isEmpty
        if !hasNativeCalls {
            let (contentCalls, cleanedContent) = ToolCallParser.extractInlineCalls(
                from: sessions[sessionIdx].messages[mIdx].content)
            if !contentCalls.isEmpty {
                inlineCalls.append(contentsOf: contentCalls)
                sessions[sessionIdx].messages[mIdx].content = cleanedContent
            }
            let visibleIsEmpty = sessions[sessionIdx].messages[mIdx].content
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if contentCalls.isEmpty, visibleIsEmpty,
               let thinking = sessions[sessionIdx].messages[mIdx].thinking, !thinking.isEmpty {
                let (thinkingCalls, cleanedThinking) = ToolCallParser.extractInlineCalls(from: thinking)
                if !thinkingCalls.isEmpty {
                    inlineCalls.append(contentsOf: thinkingCalls)
                    sessions[sessionIdx].messages[mIdx].thinking = cleanedThinking.isEmpty ? nil : cleanedThinking
                }
            }
            // Nur aktive Tools dürfen über den Ersatz-Parser ausgelöst werden.
            inlineCalls = inlineCalls.filter { ToolRegistry.shared.tool(named: $0.name)?.isEnabled == true }
        }

        if !inlineCalls.isEmpty {
            let existing = sessions[sessionIdx].messages[mIdx].toolCalls ?? []
            var seen = Set(existing.map { "\($0.name)\u{001F}\($0.arguments)" })
            let syntheticCalls = inlineCalls.compactMap { parsed -> ToolCallInfo? in
                let key = "\(parsed.name)\u{001F}\(parsed.arguments)"
                guard seen.insert(key).inserted else { return nil }
                return ToolCallInfo(id: "inline_\(UUID().uuidString.prefix(8))",
                                    index: nil, name: parsed.name, arguments: parsed.arguments)
            }
            sessions[sessionIdx].messages[mIdx].toolCalls = existing + syntheticCalls
        }

        guard let receivedToolCalls = sessions[sessionIdx].messages[mIdx].toolCalls,
              !receivedToolCalls.isEmpty else {
            finishExchange(sessionId: sessionId); return
        }

        // OpenAI verlangt, dass assistant.tool_calls[].id und tool.tool_call_id exakt
        // übereinstimmen. Ollama und einige kompatible Server lassen die ID jedoch leer.
        // Bisher bekam der Tool-Resultat-Turn dann eine zufällige andere ID und wurde vom
        // Endpoint mit HTTP 400 abgelehnt – das Modell konnte seinen fehlerhaften Aufruf nicht
        // mehr korrigieren. Die deterministische Ersatz-ID bleibt über UI, Folge-Turn und
        // persistierte Historie identisch.
        var toolCalls = Self.normalizedToolCalls(receivedToolCalls, messageID: assistantMsgId)
        if toolCalls.count > Self.maxToolCallsPerRound {
            for index in Self.maxToolCallsPerRound..<toolCalls.count {
                toolCalls[index].result =
                    "Nicht ausgeführt: In einer Tool-Runde sind höchstens \(Self.maxToolCallsPerRound) parallele Aufrufe erlaubt."
            }
        }
        sessions[sessionIdx].messages[mIdx].toolCalls = toolCalls

        // Tool-Rundenlimit: Die letzte erlaubte Runde trägt im letzten Tool-Ergebnis den Hinweis,
        // jetzt zu antworten (toolFinalRoundNotice). Ruft das Modell trotzdem noch Tools auf, werden
        // sie nicht ausgeführt und es bekommt genau eine weitere Antwort-Runde; danach endet der
        // Austausch. Kein `tool_choice: "none"` und kein Entfernen der Tools: oMLX nimmt die Tools
        // dann aus der Chat-Vorlage, und der gesamte Prompt müsste neu berechnet werden.
        if toolCallDepth >= configuredMaxToolRounds {
            for index in toolCalls.indices where toolCalls[index].result == nil {
                toolCalls[index].result = Self.toolLimitNotExecutedMessage
                toolCalls[index].limitNote = .notExecuted
            }
            sessions[sessionIdx].messages[mIdx].toolCalls = toolCalls
            guard toolCallDepth == configuredMaxToolRounds else {
                if sessions[sessionIdx].messages[mIdx].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sessions[sessionIdx].messages[mIdx].content = Self.toolLimitFallbackAnswer
                }
                finishExchange(sessionId: sessionId)
                return
            }
            toolCallDepth += 1
            continueAfterToolRound(profile: profile, sessionIdx: sessionIdx, mIdx: mIdx,
                                   assistantMsgId: assistantMsgId, sessionId: sessionId,
                                   prevMessages: prevMessages, generation: streamGeneration)
            return
        }

        // Ein Modell darf nach einer konkreten Fehlermeldung mit korrigiertem Code oder
        // geänderten Argumenten weiterarbeiten. Den exakt gleichen fehlerhaften Aufruf führen
        // wir innerhalb dieses Turns aber nicht erneut aus: Gerade bei Python-/HTML-Fehlern
        // erzeugte das sonst eine sichtbare Wiederholungsschleife ohne neuen Informationsgewinn.
        let blockedCalls = toolCalls.filter {
            blockedToolInvocationSignatures.contains(Self.toolInvocationSignature($0))
        }
        if !blockedCalls.isEmpty {
            var guardedCalls = toolCalls
            for index in guardedCalls.indices {
                let signature = Self.toolInvocationSignature(guardedCalls[index])
                guard blockedToolInvocationSignatures.contains(signature) else { continue }
                guardedCalls[index].result =
                    "Dieser identische Tool-Aufruf wurde nach einem vorherigen Fehler in diesem Turn nicht erneut ausgeführt. Ändere die Argumente oder den Code, oder fahre ohne diesen Aufruf fort."
            }
            sessions[sessionIdx].messages[mIdx].toolCalls = guardedCalls
            if blockedCalls.count == toolCalls.count {
                if sessions[sessionIdx].messages[mIdx].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sessions[sessionIdx].messages[mIdx].content =
                        "Der identische fehlerhafte Tool-Aufruf wurde nicht wiederholt. Bitte korrigiere die Argumente oder fahre ohne dieses Tool fort."
                }
                finishExchange(sessionId: sessionId)
                return
            }
        }

        toolCallDepth += 1
        let capturedCalls = sessions[sessionIdx].messages[mIdx].toolCalls ?? toolCalls
        let capturedSessionID = sessions[sessionIdx].id.uuidString
        // Generation für den asynchronen Tool-Lauf einfrieren (Audit H3): Nach einem
        // cancelStreaming() während der Tool-Ausführung ist die Generation rotiert – der
        // cancelte Task darf isStreaming und den Folge-Stream nicht mehr anfassen.
        let generation = streamGeneration

        // Der Tool-Task wird referenziert, damit cancelStreaming() ihn stoppen kann. Vorher
        // lief die Tool-Runde nach dem Nutzer-Abbruch weiter und startete danach heimlich
        // einen Folge-Stream, obwohl die UI bereits "idle" zeigte.
        toolContinuationTask = Task { [weak self] in
            // Tools über Registry parallel ausführen
            var updated = capturedCalls
            var failedSignatures: Set<String> = []
            var artifactsByIndex: [Int: [ToolArtifact]] = [:]
            await withTaskGroup(of: (Int, ToolResult).self) { group in
                for (i, tc) in updated.enumerated() where tc.result == nil {
                    group.addTask {
                        let result = await ToolRegistry.shared.execute(name: tc.name, arguments: tc.arguments, sessionID: capturedSessionID)
                        return (i, result)
                    }
                }
                for await (i, result) in group {
                    updated[i].result = result.formatted
                    updated[i].source = result.source
                    if result.isError {
                        failedSignatures.insert(Self.toolInvocationSignature(updated[i]))
                    }
                    if !result.artifacts.isEmpty { artifactsByIndex[i] = result.artifacts }
                }
            }

            // Audit H3: Nach cancelStreaming() ist isStreaming bereits false und die Queue-
            // Unterdrückung aktiv. Der frühere `isStreaming = false`-Reset hier traf dann den
            // evtl. bereits neu gestarteten Stream einer Folgenachricht und löste über den
            // didSet eine Kettenreaktion weiterer automatischer Sends aus. Cancelte Tasks
            // verlassen die Runde hier still – cancelStreaming() hat den Zustand schon gepflegt.
            if Task.isCancelled { return }
            guard let self else { return }
            let generationStillCurrent = await MainActor.run { self.streamGeneration == generation }
            guard generationStillCurrent else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.toolContinuationTask = nil
                guard let sessionIdx = self.sessions.firstIndex(where: { $0.id == sessionId }) else {
                    self.failCurrentExchange(sessionId: sessionId, targetMsgId: assistantMsgId,
                                              message: "Die Session wurde während der Tool-Ausführung gelöscht.")
                    return
                }
                // Message-Index nach dem asynchronen Tool-Lauf NEU suchen – der vorher
                // eingefrorene Index konnte veralten, wenn die Nachricht inzwischen entfernt
                // oder verschoben wurde.
                guard let mIdx = self.sessions[sessionIdx].messages.firstIndex(where: { $0.id == assistantMsgId }) else {
                    self.failCurrentExchange(sessionId: sessionId, targetMsgId: assistantMsgId,
                                              message: "Die Nachricht wurde während der Tool-Ausführung gelöscht.")
                    return
                }

                // Artefakte (Bilder, interaktives HTML, Abfragekarten) direkt als eigene Chat-
                // Nachrichten einfügen – unabhängig davon, ob das Modell sie später erwähnt.
                var waitsForUser = false
                for (index, artifacts) in artifactsByIndex.sorted(by: { $0.key < $1.key }) {
                    for artifact in artifacts {
                        switch artifact {
                        case .image(let base64):
                            self.sessions[sessionIdx].messages.append(
                                ChatMessage(role: "assistant", content: "",
                                            imageBase64: base64, imageID: UUID()))
                        case .html(let html):
                            self.sessions[sessionIdx].messages.append(
                                ChatMessage(role: "assistant", content: "", htmlArtifact: html))
                        case .quiz(let card):
                            var message = ChatMessage(role: "assistant", content: "")
                            message.quizCard = card
                            self.sessions[sessionIdx].messages.append(message)
                            waitsForUser = true
                        case .modelImage(let number):
                            // Nur für das Modell: apiMessages(for:) hängt den Screenshot nach den
                            // Tool-Ergebnissen an – in dieser Runde wie in jeder späteren Anfrage.
                            updated[index].recalledScreenshot = number
                        case .researchImages(let refs):
                            updated[index].researchImages = refs
                        }
                    }
                }

                // Beleg- und Bildnummern im ganzen Chat eindeutig machen, bevor die Ergebnisse ans
                // Modell gehen (nach den Artefakten, damit die Abbildungen mitnummeriert werden).
                let earlierCalls = self.sessions[sessionIdx].messages[..<mIdx].flatMap { $0.toolCalls ?? [] }
                updated = Self.renumberCitations(in: updated, after: earlierCalls)

                // Letzte erlaubte Runde: Das letzte Tool-Ergebnis trägt den Abschluss-Hinweis.
                if self.toolCallDepth >= min(max(self.maxToolRounds, 1), 25), let last = updated.indices.last {
                    updated[last].limitNote = .finalRound
                }
                self.sessions[sessionIdx].messages[mIdx].toolCalls = updated
                self.blockedToolInvocationSignatures.formUnion(failedSignatures)

                // Nach einer Abfragekarte wartet die App auf die Antwort des Nutzers – das Modell
                // soll die Lösung nicht gleich hinterherschreiben.
                if waitsForUser {
                    self.finishExchange(sessionId: sessionId)
                    return
                }

                self.continueAfterToolRound(profile: profile, sessionIdx: sessionIdx, mIdx: mIdx,
                                            assistantMsgId: assistantMsgId, sessionId: sessionId,
                                            prevMessages: prevMessages, generation: generation)
            }
        }
    }

    /// Startet die nächste Modell-Runde nach einer Tool-Runde. Assistant-Turn und Tool-Ergebnisse
    /// kommen aus `apiMessages(for:)` – derselben Funktion, die später den Chat-Verlauf baut. So
    /// ist diese Runde Byte für Byte identisch mit dem Verlauf der nächsten Frage (inkl.
    /// `reasoning_content`), und der Prefix-Cache des Servers greift.
    func continueAfterToolRound(profile: EndpointProfile, sessionIdx: Int, mIdx: Int,
                                assistantMsgId: UUID, sessionId: UUID,
                                prevMessages: [[String: Any]], generation: UUID) {
        guard let url = EndpointManager.chatCompletionsURL(for: profile) else {
            failCurrentExchange(sessionId: sessionId, targetMsgId: assistantMsgId,
                                message: "Ungültige Endpunkt-URL im Profil „\(profile.name)“.")
            return
        }
        let session = sessions[sessionIdx]
        var nextMessages = prevMessages
        nextMessages.append(contentsOf: apiMessages(for: session.messages[mIdx],
                                                    provider: profile.provider,
                                                    recalledScreenshot: screenshotLookup(in: session.messages)))

        let newMsgId = UUID()
        sessions[sessionIdx].messages.append(ChatMessage(id: newMsgId, role: "assistant", content: ""))

        // Defensive: Der Folge-Stream startet im "streaming"-Zustand. isStreaming ging
        // hier zwar nie auf false (das tun nur sendMessage-Reset, cancelStreaming,
        // finishExchange und Fehlerpfade) – das explizite Setzen verhindert aber die
        // historische Inkonsistenz, dass Tokens eintrafen, während die UI "idle" zeigte.
        isStreaming = true
        startStream(profile: profile, url: url, messages: nextMessages,
                    targetMsgId: newMsgId, sessionId: sessionId,
                    isFallbackAttempt: isUsingFallback,
                    generation: generation)
    }

    /// Screenshot-Nummer → Base64 für `recall_screenshot`-Bilder im Request (lazy pro Nummer).
    func screenshotLookup(in messages: [ChatMessage]) -> (Int) -> String? {
        let numbers = Self.screenshotNumbers(in: messages)
        return { number in
            guard let id = numbers.first(where: { $0.value == number })?.key,
                  let msg = messages.first(where: { $0.id == id }) else { return nil }
            return Self.imagePayloadBase64(for: msg)
        }
    }

    // MARK: - Tool-Registry-Sync

    /// Injiziert konfigurierbare Werte (searxngURL, maxBrowseCharacters) in die Registry-Tools.
    /// Muss nach loadSettings() und nach Settings-Änderungen aufgerufen werden.
    /// Screenshots einer Session für `recall_screenshot` (Base64 ggf. von Platte).
    func chatScreenshots(sessionID: String?) -> [ChatScreenshot] {
        guard let sessionID, let session = sessions.first(where: { $0.id.uuidString == sessionID }) else { return [] }
        let numbers = Self.screenshotNumbers(in: session.messages)
        return session.messages.compactMap { msg in
            guard let number = numbers[msg.id], let b64 = Self.imagePayloadBase64(for: msg) else { return nil }
            let caption = msg.content.isEmpty ? "" : "Frage dazu: „\(msg.content.prefix(120))“"
            return ChatScreenshot(number: number, base64: b64, caption: caption)
        }.sorted { $0.number < $1.number }
    }

    /// Daten-Anhänge (CSV, Excel, JSON, TXT …) einer Session für die Coding-Sandbox.
    func chatDataFiles(sessionID: String?) -> [URL] {
        guard let sessionID, let session = sessions.first(where: { $0.id.uuidString == sessionID }) else { return [] }
        let dataExtensions: Set<String> = ["csv", "tsv", "xlsx", "xls", "json", "txt", "md", "xml", "parquet", "png", "jpg", "jpeg"]
        return session.messages.compactMap { $0.documentAttachment?.url }
            .filter { dataExtensions.contains($0.pathExtension.lowercased()) && FileManager.default.isReadableFile(atPath: $0.path) }
    }

    /// Überträgt Recherche-Einstellungen, Reranker-Profil und Exa-Key in die Web-Tools.
    func syncResearchConfiguration() {
        let settings = research
        let rerankProfile = profiles.first(where: { $0.id == settings.rerankerProfileID && $0.provider == .omlx })
            ?? activeProfile.flatMap { $0.provider == .omlx ? $0 : nil }
            ?? profiles.first(where: { $0.provider == .omlx })
        let reranker: Reranker? = rerankProfile.map {
            OMLXReranker(profile: $0, model: settings.rerankerModel, timeout: settings.rerankerTimeout)
        }
        let registry = ToolRegistry.shared
        if let tool = registry.tool(named: "web_search") as? WebSearchTool {
            tool.configuration.settings = settings
            tool.configuration.reranker = reranker
            tool.configuration.exaAPIKey = exaAPIKey
        }
        if let tool = registry.tool(named: "browse_url") as? BrowseURLTool {
            tool.configuration.settings = settings
            tool.configuration.reranker = reranker
            tool.currentQuestionProvider = { [weak self] sessionID in
                guard let self else { return nil }
                let session = (sessionID.flatMap { sid in self.sessions.first(where: { $0.id.uuidString == sid }) })
                    ?? self.activeSession
                return session?.messages.last(where: { $0.role == "user" })?.content
            }
        }
    }

    func syncToolRegistry() {
        let registry = ToolRegistry.shared
        if let searchTool = registry.tool(named: "web_search") as? WebSearchTool {
            searchTool.searxngURL = searxngURL
            searchTool.isEnabled = searchEnabled
        }
        if let browseTool = registry.tool(named: "browse_url") as? BrowseURLTool {
            browseTool.maxBrowseCharacters = maxBrowseCharacters
        }
        syncResearchConfiguration()
        DownloadPermissions.shared.allowedDomains = { [weak self] in self?.downloadAllowedDomains ?? [] }
        DownloadPermissions.shared.addAllowedDomain = { [weak self] host in
            guard let self, !self.downloadAllowedDomains.contains(host) else { return }
            self.downloadAllowedDomains.append(host)
        }
        if let recall = registry.tool(named: "recall_screenshot") as? RecallScreenshotTool {
            recall.screenshotProvider = { [weak self] sessionID in self?.chatScreenshots(sessionID: sessionID) ?? [] }
        }
        if let coding = registry.tool(named: "coding_sandbox") as? CodingTool {
            coding.dataFilesProvider = { [weak self] sessionID in self?.chatDataFiles(sessionID: sessionID) ?? [] }
        }
        // Persistenz-Audit: Tool-Zustände leben in der Registry, nicht als @Published – der
        // globale Einstellungs-Autosave bekommt ihre Änderungen nicht mit. syncToolRegistry()
        // läuft ausschließlich bei nutzergesteuerten Tool-Änderungen (und einmal im Init mit
        // identischem Zustand) – hier ist ein direkter Save der richtige Ort, damit Tool-
        // Toggles auch bei ESC-Close des Settings-Sheets + Crash erhalten bleiben.
        saveSettings()
    }

    /// Aktiviert/deaktiviert Web-Suche UND URL-Browsing gemeinsam – passend zum Label "Suche &
    /// Browsing aktivieren" in SearchTabView. Vorher setzte dieser eine Schalter NUR `searchEnabled`
    /// (→ nur web_search.isEnabled via syncToolRegistry), browse_url.isEnabled wurde davon NIE
    /// berührt und blieb unabhängig vom Toggle-Zustand auf seinem Default (aus) – Browsing
    /// funktionierte dadurch nie, obwohl der Schalter das Gegenteil versprach. Ruft zusätzlich
    /// sofort saveSettings()/syncToolRegistry() auf: die reinen @Published-Properties allein wirkten
    /// sich vorher erst nach einem Neustart (oder einem zufälligen Toggle im Tools-Tab) tatsächlich
    /// auf die ToolRegistry aus, da nur syncToolRegistry() die Werte in die Live-Tool-Instanzen
    /// überträgt.
    func setSearchAndBrowsingEnabled(_ enabled: Bool) {
        searchEnabled = enabled
        if let browseTool = ToolRegistry.shared.tool(named: "browse_url") {
            browseTool.isEnabled = enabled
        }
        syncToolRegistry()
        saveSettings()
    }

    static func normalizedToolCalls(_ calls: [ToolCallInfo], messageID: UUID) -> [ToolCallInfo] {
        calls.enumerated().map { offset, call in
            guard call.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return call }
            var normalized = call
            normalized.id = "call_\(messageID.uuidString.lowercased())_\(offset)"
            return normalized
        }
    }
}
