import SwiftUI

// MARK: - Arbeitsschritte einer Antwort
//
// Eine Antwort des Modells besteht oft aus mehreren Nachrichten (Denken → Tool → Denken → Tool →
// Antwort). Statt alles einzeln untereinander zu stapeln, bündelt diese Gruppe die Schritte:
// Während die Antwort entsteht, ist sie offen und zeigt den aktuellen Schritt live; sobald der
// Antworttext fließt, faltet sie sich sanft zu einer Zeile („4 Schritte · 7 Quellen“). Jeder
// Schritt bleibt einzeln aufklappbar (Gedankengang, Websuche mit Quellenliste, Code + Terminal).
// Ergebnisse (Plot, Simulation, Quizkarte, Antwort) stehen außerhalb, darunter.

nonisolated struct WorkStep: Identifiable, Equatable {
    enum Kind: Equatable {
        case thinking(String)
        case note(String)
        case tool(ToolCallInfo)
    }
    let id: String
    let kind: Kind

    /// Schritte aller Nachrichten einer Antwort, in Entstehungsreihenfolge.
    static func steps(from messages: [ChatMessage]) -> [WorkStep] {
        var result: [WorkStep] = []
        for message in messages {
            if let thinking = message.thinking?.trimmingCharacters(in: .whitespacesAndNewlines), !thinking.isEmpty {
                result.append(WorkStep(id: "\(message.id)-t", kind: .thinking(thinking)))
            }
            guard let tools = message.toolCalls, !tools.isEmpty else { continue }
            // Kurzer Text vor einem Tool-Aufruf („Ich rechne das kurz nach …“) ist Zwischenstand.
            let note = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty, !hasAnswerText(message) {
                result.append(WorkStep(id: "\(message.id)-n", kind: .note(note)))
            }
            for (index, tool) in tools.enumerated() {
                result.append(WorkStep(id: "\(message.id)-\(index)", kind: .tool(tool)))
            }
        }
        return result
    }

    /// Hat diese Nachricht Antworttext (statt Zwischenstand vor einem Tool)? Längerer oder
    /// strukturierter Text gehört auch dann zur Antwort, wenn danach noch ein Tool folgt –
    /// manche Modelle erklären zuerst ausführlich und rechnen dann.
    static func hasAnswerText(_ message: ChatMessage) -> Bool {
        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if message.toolCalls?.isEmpty ?? true { return true }
        return text.count > 280 || text.contains("\n\n") || text.hasPrefix("#")
    }
}

struct WorkStepsView: View, Equatable {
    let messages: [ChatMessage]
    /// Diese Antwort wird gerade generiert.
    let isRunning: Bool

    static func == (lhs: WorkStepsView, rhs: WorkStepsView) -> Bool {
        lhs.isRunning == rhs.isRunning && lhs.messages == rhs.messages
    }

    @State private var isExpanded: Bool
    @State private var userToggled = false

    init(messages: [ChatMessage], isRunning: Bool) {
        self.messages = messages
        self.isRunning = isRunning
        _isExpanded = State(initialValue: isRunning && !messages.contains(where: WorkStep.hasAnswerText))
    }

    private var steps: [WorkStep] { WorkStep.steps(from: messages) }
    private var answerStarted: Bool { messages.contains(where: WorkStep.hasAnswerText) }
    private var toolSteps: [ToolCallInfo] {
        steps.compactMap { if case .tool(let call) = $0.kind { return call } else { return nil } }
    }

    var body: some View {
        let steps = self.steps
        Group {
            if steps.isEmpty {
                // Noch nichts zu zeigen: nur während der Generierung ein ruhiger Platzhalter.
                if isRunning && !answerStarted {
                    liveLabel(currentActivity)
                }
            } else if toolSteps.isEmpty, steps.count == 1, case .thinking(let text) = steps[0].kind {
                // Reines Nachdenken ohne Werkzeuge: keine Gruppe, nur der aufklappbare Gedankengang.
                ThinkingStepRow(text: text, isLive: isRunning && !answerStarted)
            } else {
                group(steps)
            }
        }
        .onChange(of: answerStarted) { _, started in
            // Sobald die Antwort fließt, faltet sich die Gruppe zusammen (außer der Nutzer hat selbst geklickt).
            // Server wie oMLX liefern den Tool-Aufruf erst nach dem Text davor: Entpuppt sich der
            // vermeintliche Antworttext als Zwischenschritt, öffnet sich die Gruppe wieder.
            guard !userToggled else { return }
            if started {
                withAnimation(.snappy(duration: 0.35)) { isExpanded = false }
            } else if isRunning {
                withAnimation(.snappy(duration: 0.35)) { isExpanded = true }
            }
        }
        .onChange(of: isRunning) { _, running in
            if !running, !userToggled { withAnimation(.snappy(duration: 0.35)) { isExpanded = false } }
        }
    }

    // MARK: Gruppe

    private func group(_ steps: [WorkStep]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(steps)
            if isExpanded {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        timelineRow(step, isLast: index == steps.count - 1, isActive: isRunning && !answerStarted && index == steps.count - 1)
                    }
                }
                .padding(.top, DS.Space.s)
                .padding(.leading, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if isRunning, !answerStarted, case .thinking(let text)? = steps.last?.kind {
                // Eingeklappt, aber das Modell denkt gerade: fortlaufender Gedanke unter der Zeile.
                ThinkingLivePreview(text: text)
                    .padding(.top, 4)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }

    private func header(_ steps: [WorkStep]) -> some View {
        Button {
            userToggled = true
            withAnimation(.snappy(duration: 0.3)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: DS.Space.s) {
                if isRunning && !answerStarted {
                    ProgressView().controlSize(.mini).frame(width: 16)
                    Text(currentActivity)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: currentActivity)
                } else {
                    Image(systemName: hasError ? "exclamationmark.triangle" : "checklist")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(hasError ? Color.orange : DS.Ink.accent)
                        .frame(width: 16)
                    Text(summary(steps))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: DS.Space.s)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, DS.Space.m)
            .background(Capsule().fill(DS.Surface.chip))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRunning ? currentActivity : summary(steps))
        .accessibilityHint(isExpanded ? "Arbeitsschritte einklappen" : "Arbeitsschritte anzeigen")
    }

    @ViewBuilder
    private func timelineRow(_ step: WorkStep, isLast: Bool, isActive: Bool) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            // Zeitleiste: Punkt + Verbindungslinie zum nächsten Schritt
            VStack(spacing: 0) {
                Circle()
                    .fill(isActive ? DS.Ink.accent : Color.secondary.opacity(0.35))
                    .frame(width: 6, height: 6)
                    .padding(.top, 11)
                if !isLast {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 10)

            Group {
                switch step.kind {
                case .thinking(let text):
                    ThinkingStepRow(text: text, isLive: isActive)
                case .note(let text):
                    Text(text)
                        .font(.system(size: 12.5, design: .rounded))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 5)
                case .tool(let call):
                    ToolActivityView(call: call)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Status

    private var hasError: Bool {
        toolSteps.contains { ToolCallPresentation(call: $0).isError }
    }

    private func summary(_ steps: [WorkStep]) -> String {
        let tools = toolSteps
        if tools.contains(where: { $0.limitNote != nil }) {
            return "Tool-Limit erreicht – Antwort aus den bisherigen Ergebnissen"
        }
        var parts = ["\(steps.count) Schritt\(steps.count == 1 ? "" : "e")"]
        let sources = tools.filter { $0.name == "web_search" }.reduce(0) { $0 + ToolCallPresentation(call: $1).sources.count }
            + tools.filter { $0.name == "browse_url" && $0.result != nil }.count
        if sources > 0 { parts.append("\(sources) Quelle\(sources == 1 ? "" : "n")") }
        if tools.contains(where: { $0.name == "coding_sandbox" }) { parts.append("Code ausgeführt") }
        return parts.joined(separator: " · ")
    }

    /// Was gerade passiert – für die Kopfzeile während der Generierung.
    private var currentActivity: String {
        guard let last = messages.last else { return "Liest die Frage …" }
        if let tools = last.toolCalls, !tools.isEmpty {
            if let running = tools.last(where: { $0.result == nil }) {
                return ToolCallPresentation(call: running).title
            }
            return "Wertet die Ergebnisse aus …"
        }
        if last.thinking != nil { return "Denkt nach …" }
        return messages.count > 1 ? "Wertet die Ergebnisse aus …" : "Liest die Frage …"
    }

    private func liveLabel(_ text: String) -> some View {
        HStack(spacing: DS.Space.s) {
            ProgressView().controlSize(.mini)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Gedankengang als Schritt

struct ThinkingStepRow: View {
    let text: String
    /// Wird gerade noch geschrieben – dann läuft eine kurze Vorschau mit.
    let isLive: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Ink.accent)
                        .symbolEffect(.pulse, isActive: isLive)
                    Text(isLive ? "Denkt nach …" : "Gedankengang")
                        .font(.callout)
                        .foregroundStyle(.primary)
                    Text(wordInfo)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: DS.Space.s)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.vertical, 6)
                .padding(.horizontal, DS.Space.m)
                .background(Capsule().fill(DS.Surface.chip))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Gedankengang einklappen" : "Gedankengang anzeigen")

            if isExpanded {
                // Bereinigt (ohne Markdown-Zeichen) – gespeichert/gesendet wird das Original.
                // Während des Schreibens nur das Ende layouten (wachsender Text kostet sonst jedes Update).
                Text(ThinkingText.display(isLive && text.count > 3000 ? "…" + text.suffix(3000) : text))
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DS.Space.m)
                    .padding(.vertical, DS.Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous).fill(DS.Surface.chip.opacity(0.6)))
                    .transition(.opacity)
            } else if isLive {
                ThinkingLivePreview(text: text)
            }
        }
    }

    private var wordInfo: String {
        // Während des Schreibens grob über die Länge (O(1)), danach exakt.
        isLive ? "~\(text.utf16.count / 6) Wörter" : "\(text.split(whereSeparator: \.isWhitespace).count) Wörter"
    }
}


/// Fortlaufende Vorschau des aktuellen Gedankens: bereinigt, ab einer Satzgrenze, zweizeilig.
struct ThinkingLivePreview: View {
    let text: String

    var body: some View {
        Text(ThinkingText.livePreview(text))
            .font(.system(size: 11.5, design: .rounded))
            .foregroundStyle(.tertiary)
            .lineLimit(2, reservesSpace: false)
            .truncationMode(.head)
            .padding(.horizontal, DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.2), value: text.count / 40)
    }
}

/// Anzeige-Bereinigung für den Gedankengang. Qwen & Co. schreiben ihr Thinking oft als Markdown
/// (Aufzählungen, **fett**, Überschriften) – ungerendert wirkt das unruhig. Nur für die Anzeige:
/// gespeichert und an das Modell zurückgegeben wird immer der Originaltext.
nonisolated enum ThinkingText {
    /// Ohne Markdown-Zeichen, Absätze bleiben erhalten, Listenpunkte werden zu eigenen Zeilen.
    static func display(_ raw: String) -> String {
        var lines: [String] = []
        for line in raw.components(separatedBy: "\n") {
            var l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("```") { continue }
            if l.isEmpty {
                if lines.last?.isEmpty == false { lines.append("") }
                continue
            }
            if l.allSatisfy({ "-*_=#".contains($0) || $0 == " " }) { continue } // Trennlinien
            l = stripLinePrefix(l)
            l = stripInline(l)
            if !l.isEmpty { lines.append(l) }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Letzter (fortlaufender) Gedanke als eine Zeile – beginnt möglichst an einer Satzgrenze.
    static func livePreview(_ raw: String, maxCharacters: Int = 240) -> String {
        let flat = display(String(raw.suffix(maxCharacters * 3)))
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flat.count > maxCharacters else { return flat }
        let tail = String(flat.suffix(maxCharacters))
        // Am ersten Satzende im vorderen Teil abschneiden, damit kein Wortfragment vorne steht.
        let probe = tail.prefix(maxCharacters / 2)
        if let boundary = probe.range(of: #"[.!?:;] "#, options: .regularExpression) {
            return String(tail[boundary.upperBound...])
        }
        if let space = tail.firstIndex(of: " ") { return "…" + tail[tail.index(after: space)...] }
        return "…" + tail
    }

    private static func stripLinePrefix(_ line: String) -> String {
        var l = line
        while l.hasPrefix(">") { l = String(l.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if l.hasPrefix("#") { l = String(l.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces) }
        // Aufzählungen: "- ", "* ", "• ", "+ ", "1. ", "2) ", "- [ ] "
        if let match = l.range(of: #"^([-*•+]|\d{1,2}[.)])\s+(\[[ xX]\]\s+)?"#, options: .regularExpression) {
            l = String(l[match.upperBound...])
        }
        return l
    }

    private static func stripInline(_ line: String) -> String {
        var l = line
        for marker in ["**", "__", "`"] { l = l.replacingOccurrences(of: marker, with: "") }
        // Einzelne *Betonung* entfernen, aber Rechenzeichen wie 2 * 3 stehen lassen.
        l = l.replacingOccurrences(of: #"(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])"#, with: "$1", options: .regularExpression)
        // [Text](URL) → Text
        l = l.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        return l.trimmingCharacters(in: .whitespaces)
    }
}
