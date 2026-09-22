import SwiftUI

/// Popover für "Text erklären": Eigenständiger Mini-Chat über die markierte Textstelle.
///
/// Neu nach Audit C7/U1/U2 (vorher vierfach kaputt):
/// 1. Kontext-Fenster statt Vollhistorie: Nur die letzten paar Nachrichten mit der
///    markierten Stelle im Zentrum, als eingebetteter Kontextblock in der ersten Frage.
///    Folgefragen führen ausschließlich die Popover-eigene Konversation weiter (stabiler
///    Prompt-Präfix, KV-Cache-freundlich, keine Kontext-Pollution durch Nebenschauplätze).
/// 2. Antworten werden per MarkdownView gerendert (kein rohes `**fett**` als Text).
/// 3. Nur gültige Rollen (system/user/assistant) im API-Payload; der Lernmodus-
///    System-Prompt der App wird wiederverwendet. Document-/UI-System-Nachrichten und
///    Tool-Verläufe werden nie gesendet.
/// 4. Echtes Stream-Ende über ChatViewModel.streamCompletion (Latch) statt 60-s-Sleep;
///    Chunk-Reihenfolge über einen thread-sicheren Puffer garantiert, UI-Updates per
///    Message-ID statt `count - 1`, 250-ms-Throttle statt Update pro Chunk.
struct InlineExplainPopover: View {
    let selectedText: String
    /// Nachrichten der Hauptsession bis einschließlich der markierten Nachricht
    /// (Basis für das Kontext-Fenster der ersten Frage).
    let history: [ChatMessage]
    /// ID der Nachricht, in der die Markierung liegt – der Kontext wird daraus zur Fragezeit
    /// selbst geschnitten, statt eine eingefrorene Prefix-Kopie zu halten.
    let markedMessageId: UUID
    let chatViewModel: ChatViewModel
    var fontScale: Double = 1.0
    let onDismiss: () -> Void

    @State private var userQuestion: String = ""
    @State private var popoverMessages: [ChatMessage] = []
    @State private var isThinking = false
    @State private var activeStream: Task<Void, Never>? = nil
    @State private var flushLoop: Task<Void, Never>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Text erklären")
                    .font(.headline)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }

            // Markierte Stelle
            ScrollView {
                Text(selectedText)
                    .font(.subheadline)
                    .italic()
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 80)
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(6)

            // Mini-Chat
            if !popoverMessages.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(popoverMessages) { msg in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(msg.role == "user" ? "Du" : "LernAssist")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.secondary)

                                if msg.role == "user" {
                                    Text(msg.content)
                                        .font(.body)
                                } else if msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.mini)
                                        Text("Antwortet...")
                                            .font(.caption)
                                            .foregroundColor(.secondary).italic()
                                    }
                                } else {
                                    MarkdownView(markdown: msg.content, fontScale: fontScale)
                                }
                            }
                            .padding(8)
                            .background(msg.role == "user" ? Color.blue.opacity(0.1) : Color.secondary.opacity(0.1))
                            .cornerRadius(8)
                        }
                    }
                }
                .frame(maxHeight: 320)
            } else if isThinking {
                Divider()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Nachdenken...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            }

            Spacer(minLength: 0)

            // Eingabe
            HStack {
                TextField("Was genau möchtest du dazu wissen?", text: $userQuestion)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onSubmit(askQuestion)

                Button(action: askQuestion) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundColor(canSend ? .blue : .secondary)
                        .font(.title2)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!canSend)
            }
        }
        .padding()
        .frame(width: 450, height: popoverMessages.isEmpty ? 220 : 500)
        .onDisappear {
            activeStream?.cancel()
            flushLoop?.cancel()
        }
    }

    private var canSend: Bool {
        !userQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isThinking
    }

    // MARK: - Frage stellen

    private func askQuestion() {
        let question = userQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, activeStream == nil else { return }

        let isFirstQuestion = popoverMessages.isEmpty
        let userMsg = ChatMessage(role: "user", content: question)
        let questionId = userMsg.id
        popoverMessages.append(userMsg)
        let assistantMsg = ChatMessage(role: "assistant", content: "")
        let targetId = assistantMsg.id
        popoverMessages.append(assistantMsg)
        userQuestion = ""
        isThinking = true

        // Payload: Nur gültige Rollen. Die ERSTE Frage trägt den Kontextblock (markierte
        // Stelle + umgebendes Fenster), Folgefragen führen nur die Popover-Konversation
        // weiter – der Prompt-Präfix bleibt über alle Folgefragen stabil.
        var messages: [[String: Any]] = [["role": "system", "content": buildSystemPrompt()]]
        if isFirstQuestion {
            messages.append(["role": "user", "content": contextPrompt(question: question)])
        } else {
            // Die neue Nutzerfrage wurde oben bereits für die UI eingefügt. Sie darf im
            // Verlauf nicht erneut auftauchen, weil sie unten exakt einmal angehängt wird.
            // Sonst erhält das Modell bei jeder Folgefrage denselben Text doppelt.
            for msg in Self.historyForFollowUp(
                popoverMessages,
                excludingCurrentQuestion: questionId,
                pendingAssistantMessage: targetId
            ) {
                messages.append(["role": msg.role, "content": msg.content])
            }
            messages.append(["role": "user", "content": question])
        }

        // Chunks kommen auf der URLSession-Delegate-Queue, UI-Updates auf den Main-Actor.
        let buffer = ChunkBuffer()
        let stream = chatViewModel.streamCompletion(
            profile: nil,
            messages: messages,
            onChunk: { chunk in buffer.append(chunk) },
            onError: { message in
                DispatchQueue.main.async {
                    if let idx = popoverMessages.firstIndex(where: { $0.id == targetId }) {
                        popoverMessages[idx].content = "Fehler: \(message)"
                    }
                }
            }
        )
        activeStream = stream

        // 250-ms-Flush statt UI-Update pro Chunk: MarkdownView rendert in einem WKWebView,
        // ein Update pro Chunk wäre unnötig teuer (gleiche Strategie wie der Haupt-Chat).
        // Das Stream-Ende wird über `stream.value` abgewartet – ein ECHTES Ende statt
        // des früheren 60-Sekunden-Sleep-Hacks (Audit C7/U2).
        flushLoop = Task {
            var lastApplied = ""
            func apply(_ text: String) {
                guard text != lastApplied,
                      let idx = popoverMessages.firstIndex(where: { $0.id == targetId }) else { return }
                lastApplied = text
                popoverMessages[idx].content = text
            }
            let ticker = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    apply(buffer.current)
                }
            }
            await stream.value // endet bei Erfolg, Fehler oder Abbruch
            ticker.cancel()
            apply(buffer.current) // finaler Drain nach Stream-Ende
            isThinking = false
            activeStream = nil
        }
    }

    // MARK: - Prompt-Bau

    private func buildSystemPrompt() -> String {
        """
        \(chatViewModel.prompt(for: chatViewModel.learningStyle))

        Du bist der Erklär-Assistent zu einer vom Nutzer markierten Textstelle. Antworte kompakt und auf die Frage fokussiert. Alles Nötige steht im Kontextblock – spekuliere nicht über den restlichen Chatverlauf.
        """
    }

    /// Kontext-Fenster (statt Vollhistorie): die letzten paar Nutzer-/Assistent-Nachrichten
    /// bis zur markierten Nachricht, die markierte Nachricht selbst nur als Fenster um die
    /// Markierung (~500 Zeichen je Seite).
    private func contextPrompt(question: String) -> String {
        // Zur Fragezeit schneiden (Audit U4/U3): keine eingefrorene Prefix-Kopie, sondern der
        // aktuelle Verlauf bis zur markierten Nachricht – dadurch ist der Kontext auch dann
        // aktuell, wenn ältere Nachrichten nach dem Öffnen des Popovers noch erweitert wurden.
        let upToMarked: [ChatMessage]
        if let idx = history.firstIndex(where: { $0.id == markedMessageId }) {
            upToMarked = Array(history.prefix(idx + 1))
        } else {
            upToMarked = []
        }
        let candidates = upToMarked.filter { $0.role == "user" || $0.role == "assistant" }
        var lines: [String] = []
        for msg in candidates.suffix(contextMessages) {
            let body = msg.id == markedMessageId
                ? windowAroundSelection(in: msg.content)
                : truncated(msg.content, limit: contextCharLimit)
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            lines.append("\(msg.role == "user" ? "Nutzer" : "Assistent"): \(body)")
        }

        return """
        Der Nutzer hat in einem Chat folgende Stelle markiert:
        <SELECTION>
        \(selectedText)
        </SELECTION>

        Umgebender Chatverlauf (gekürzt):
        <CONTEXT>
        \(lines.joined(separator: "\n\n"))
        </CONTEXT>

        Frage: \(question)
        """
    }

    /// ±`selectionRadius` Zeichen um die Markierung; Auslassungszeichen, falls gekürzt.
    private func windowAroundSelection(in content: String) -> String {
        guard !selectedText.isEmpty, let range = content.range(of: selectedText) else {
            return truncated(content, limit: selectionRadius * 2 + selectedText.count)
        }
        let start = content.index(range.lowerBound, offsetBy: -selectionRadius, limitedBy: content.startIndex) ?? content.startIndex
        let end = content.index(range.upperBound, offsetBy: selectionRadius, limitedBy: content.endIndex) ?? content.endIndex
        let ellipsisStart = start > content.startIndex ? "…" : ""
        let ellipsisEnd = end < content.endIndex ? "…" : ""
        return ellipsisStart + content[start..<end] + ellipsisEnd
    }

    private func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    /// Der bereits sichtbare aktuelle Nutzertext und der noch leere Antwortplatz gehören nicht
    /// in den Verlauf einer Folgefrage. Die Methode ist absichtlich rein, damit die zentrale
    /// Payload-Regel ohne Netzwerk oder SwiftUI-Zustand regressionssicher testbar bleibt.
    static func historyForFollowUp(
        _ messages: [ChatMessage],
        excludingCurrentQuestion questionID: UUID,
        pendingAssistantMessage assistantID: UUID
    ) -> [ChatMessage] {
        messages.filter { $0.id != questionID && $0.id != assistantID }
    }

    // Konfiguration (Magic Numbers benannt statt verstreuter Literale)
    private let contextMessages = 6
    private let contextCharLimit = 800
    private let selectionRadius = 500
}

/// Thread-sicherer Chunk-Puffer: Die Reihenfolge der Chunks bleibt garantiert erhalten
/// (Audit U2 – vorher hatte jeder Chunk sein eigenes async Task-Gefäß ohne Ordnungsgarantie).
private final class ChunkBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ chunk: String) {
        lock.lock(); defer { lock.unlock() }
        text += chunk
    }

    var current: String {
        lock.lock(); defer { lock.unlock() }
        return text
    }
}
