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
        VStack(alignment: .leading, spacing: DS.Space.m) {
            header

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        ForEach(Array(popoverMessages.enumerated()), id: \.element.id) { index, msg in
                            // Die automatische erste Frage wird nicht angezeigt – nur echte Rückfragen.
                            if msg.role == "user" {
                                if index > 0 { followUpBubble(msg.content) }
                            } else if msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                HStack(spacing: DS.Space.s) {
                                    ProgressView().controlSize(.mini)
                                    Text(L("Erklärt …")).font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            } else {
                                MarkdownView(markdown: msg.content, fontScale: fontScale * 0.95)
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                }
                .frame(maxHeight: 300)
                .onChange(of: popoverMessages.last?.content) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }

            followUpField
        }
        .padding(DS.Space.l)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(DS.Surface.canvas)
        .onAppear {
            // Schnelle Auskunft: sofort erklären, Rückfragen optional.
            if popoverMessages.isEmpty { ask(Self.defaultQuestion) }
        }
        .onDisappear {
            activeStream?.cancel()
            flushLoop?.cancel()
        }
    }

    private static let defaultQuestion = "Erkläre den markierten Begriff."

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.Ink.accent)
                .frame(width: 22, height: 22)
                .background(Circle().fill(DS.Surface.selection))
            Text(selectedText)
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .lineLimit(2)
                .truncationMode(.tail)
                .textSelection(.enabled)
            Spacer(minLength: DS.Space.s)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(DS.Surface.chip))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(L("Schließen"))
        }
    }

    private func followUpBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .font(.system(size: 12.5, design: .rounded))
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous).fill(DS.Surface.bubbleUser))
        }
    }

    private var followUpField: some View {
        HStack(spacing: DS.Space.s) {
            TextField(L("Nachfragen …"), text: $userQuestion)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .rounded))
                .onSubmit(askQuestion)
            Button(action: askQuestion) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(canSend ? DS.Accent.brand : Color.secondary.opacity(0.35)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel(L("Nachfrage senden"))
        }
        .padding(.leading, DS.Space.m)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(Capsule().fill(DS.Surface.chip))
    }

    private var canSend: Bool {
        !userQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isThinking
    }

    // MARK: - Frage stellen

    private func askQuestion() {
        let question = userQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        ask(question)
    }

    private func ask(_ question: String) {
        guard activeStream == nil else { return }

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
        flushLoop = Task { @MainActor in
            var lastApplied = ""
            @MainActor func apply(_ text: String) {
                guard text != lastApplied,
                      let idx = popoverMessages.firstIndex(where: { $0.id == targetId }) else { return }
                lastApplied = text
                popoverMessages[idx].content = text
            }
            let ticker = Task { @MainActor in
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
        Du gibst schnelle, präzise Erklärungen zu einer markierten Stelle aus einem Lernchat. \
        Erkläre den Begriff im Zusammenhang dieser Stelle – so kurz wie möglich, so ausführlich wie nötig: \
        meist 2–5 Sätze, bei Bedarf eine kurze Aufzählung oder Formel. Keine Einleitung, keine Wiederholung \
        der Frage, keine Rückfragen. Antworte in der Sprache des Kontexts.
        """
    }

    /// Schlanker Kontext: Thema des Chats und die Stelle rund um die Markierung – kein Chatverlauf.
    private func contextPrompt(question: String) -> String {
        let session = chatViewModel.sessions.first { $0.messages.contains { $0.id == markedMessageId } }
        let surroundingText: String
        if let markedMsg = history.first(where: { $0.id == markedMessageId }) {
            surroundingText = windowAroundSelection(in: markedMsg.content)
        } else {
            surroundingText = selectedText
        }
        var topic = session?.title ?? ""
        if let subject = session?.subject, !subject.isEmpty { topic += topic.isEmpty ? subject : " (\(subject))" }

        return """
        \(topic.isEmpty ? "" : "Thema des Chats: \(topic)\n")Markiert: „\(selectedText)“

        Stelle im Text:
        \(surroundingText)

        \(question)
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
    private var selectionRadius: Int { max(50, chatViewModel.inlineExplainRadius) }
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
