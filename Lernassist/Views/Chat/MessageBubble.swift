import SwiftUI
import AppKit

// MARK: - MessageBubble
// Nutzt Equatable, um die Re-Evaluation während des Streamings zu minimieren (Performance!).

struct MessageBubble: View, Equatable {
    static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        // history ist Teil der Gleichheit (Audit U3): Das InlineExplainPopover baut daraus
        // seinen Kontext – ohne diesen Vergleich hätte SwiftUI bei Content-Änderungen in
        // älteren Nachrichten die Neuberechnung des Bubbles (und damit die aktualisierte
        // Popover-Historie) übersprungen. Da ChatView allen Bubbles dieselbe Array-Instanz
        // (COW) übergibt statt Prefix-Kopien, ist der Vergleich billig.
        lhs.message == rhs.message &&
        lhs.history == rhs.history &&
        lhs.isStreaming == rhs.isStreaming &&
        lhs.isContinuation == rhs.isContinuation &&
        lhs.fontScale == rhs.fontScale
    }
    let message: ChatMessage
    let history: [ChatMessage]
    /// Referenz auf den ChatViewModel (nur für das InlineExplainPopover; bewusst kein
    /// @ObservedObject – der Bubble wird über `message`/`isStreaming` Equatable-diffed,
    /// eine Beobachtung würde den Re-Render-Sturm pro Token wieder einführen (Audit U13).
    let chatViewModel: ChatViewModel
    /// Nur true für die letzte Nachricht während aktiver Generierung
    let isStreaming: Bool
    let isContinuation: Bool
    /// Schriftgrößen-Multiplikator (Erscheinungsbild-Einstellung). Muss Teil der Equatable-Prüfung
    /// sein, sonst überspringt SwiftUIs Diffing die Neuberechnung bei einer reinen Größenänderung,
    /// wenn sich sonst nichts an der Nachricht geändert hat.
    var fontScale: Double = 1.0
    /// Optional: Callback für "Andere Erklärung"-Button (nur Assistent-Nachrichten)
    var onExplainDifferently: (() -> Void)? = nil
    /// Optional: Callback für "Confidence Score"-Button
    var onCheckConfidence: (() -> Void)? = nil
    /// Optional: Callback für "Verifizieren"-Button
    var onVerify: (() -> Void)? = nil
    /// Optional: Callback für "Abzweigen" (Phase H) – startet einen neuen Chat ab dieser Antwort.
    var onBranch: (() -> Void)? = nil
    /// Optional: „Frage im neuen Zweig bearbeiten“ – der Ursprungschat bleibt erhalten,
    /// der neue Zweig enthält nur den Kontext vor dieser User-Nachricht.
    var onEditFromHere: (() -> Void)? = nil
    /// Optional: Fehler-Retry (Fehler-UX) – fehlgeschlagene Antwort neu generieren.
    var onRetryFailed: (() -> Void)? = nil
    /// Optional: Fehler-Rollback (Fehler-UX) – Frage zurück ins Eingabefeld legen.
    var onRollbackFailed: (() -> Void)? = nil
    /// Hover-Zustand für die Einblendung der Aktionsleiste (Phase G).
    @State private var isHovered = false
    @State private var isThinkingExpanded = false
    @State private var didCopy = false
    struct ExplanationRequest: Identifiable { let id = UUID(); let text: String }
    @State private var selectedExplanation: ExplanationRequest? = nil

    init(
        message: ChatMessage,
        history: [ChatMessage] = [],
        chatViewModel: ChatViewModel,
        isStreaming: Bool = false,
        isContinuation: Bool = false,
        fontScale: Double = 1.0,
        onExplainDifferently: (() -> Void)? = nil,
        onCheckConfidence: (() -> Void)? = nil,
        onVerify: (() -> Void)? = nil,
        onBranch: (() -> Void)? = nil,
        onEditFromHere: (() -> Void)? = nil,
        onRetryFailed: (() -> Void)? = nil,
        onRollbackFailed: (() -> Void)? = nil
    ) {
        self.message = message
        self.history = history
        self.chatViewModel = chatViewModel
        self.isStreaming = isStreaming
        self.isContinuation = isContinuation
        self.fontScale = fontScale
        self.onExplainDifferently = onExplainDifferently
        self.onCheckConfidence = onCheckConfidence
        self.onVerify = onVerify
        self.onBranch = onBranch
        self.onEditFromHere = onEditFromHere
        self.onRetryFailed = onRetryFailed
        self.onRollbackFailed = onRollbackFailed
        self._isThinkingExpanded = State(initialValue: false)
        self._didCopy = State(initialValue: false)
    }

    private var isUser: Bool { message.role == "user" }
    
    /// Verhindert das Anzeigen von komplett leeren "Geister-Bubbles"
    private var isCompletelyEmpty: Bool {
        // Ein Thought-Prozess ist NIEMALS leer
        if message.thinking != nil { return false }
        if let tools = message.toolCalls, !tools.isEmpty { return false }
        if !message.content.isEmpty { return false }
        if message.imageID != nil { return false }
        if message.htmlArtifact != nil { return false }
        return true
    }

    var body: some View {
        if isCompletelyEmpty && message.role != "system" {
            EmptyView()
        } else if message.role == "system" {
            systemBubbleContent
        } else {
            mainBubbleContent
        }
    }

    // MARK: - Nutzer-Nachricht (GUI-Neubau)
    //
    // Rechtsbündige Akzent-Bubble mit asymmetrischen Radien (moderner Chat-Look), Inhalt als
    // reines SwiftUI-Text (bewusst KEIN MarkdownView/WKWebView für Nutzer-Fragen: Fragen sind
    // praktisch immer Fließtext – das spart pro Nutzer-Nachricht einen ganzen WebView-Prozess-
    // Anteil, siehe WKWebView-Memory-Faktor Audit U17). Beim Hover erscheint ein Stift-Button
    // zum Erstellen eines Bearbeitungs-Zweigs (der Ursprungschat bleibt unverändert).

    private var userMessageContent: some View {
        HStack(alignment: .top, spacing: DS.Space.xs) {
            Spacer(minLength: 40)
            if isHovered, let edit = onEditFromHere {
                Button(action: edit) {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Frage im neuen Zweig bearbeiten – der bisherige Chat bleibt erhalten")
            }
            VStack(alignment: .trailing, spacing: DS.Space.s) {
                if let imgID = message.imageID {
                    OptimizedImageView(imageID: imgID, base64: message.imageBase64)
                        .frame(maxWidth: 300)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
                }
                if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(message.content)
                        .font(.system(size: 13.5 * fontScale, design: .rounded))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s + 2)
            .frame(maxWidth: 420, alignment: .trailing)
            .background(userBubbleShape.fill(DS.Surface.bubbleUser))
        }
    }

    /// Asymmetrische Sprechblase: runde Ecken außen, kleinere Ecke Richtung Verlauf.
    private var userBubbleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
    }

    // MARK: - Assistent-Nachricht (GUI-Neubau)
    //
    // Kleines Icon als Absender-Markierung (statt Doppel-Bubble), Inhalt direkt auf der
    // Content-Fläche – das ist der Chat-Standard-Look moderner Assistenten und wirkt deutlich
    // ruhiger als eckige Boxen um langen Text.

    private var assistantMessageContent: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            if !isContinuation {
                Circle()
                    .fill(DS.Ink.accent.gradient.opacity(0.16))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: "graduationcap.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DS.Ink.accent.gradient)
                    )
                    .padding(.top, 2)
            } else {
                Spacer().frame(width: 30)
            }

            VStack(alignment: .leading, spacing: DS.Space.s) {
                // Tool-Artefakt: interaktives HTML (coding_sandbox), sandboxed direkt gerendert
                if let html = message.htmlArtifact {
                    HTMLArtifactView(html: html)
                }

                // Tool Calls
                if let tools = message.toolCalls, !tools.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        // Identität über die Position, nicht über tool.id (Audit U16): Inline
                        // geparste Tool-Calls haben oft den leeren String als id – mehrere
                        // Badges mit derselben (leeren) id ließen SwiftUI die Views bei jedem
                        // Update neu zuordnen, die @State-expansion klapperte ungewollt auf/zu.
                        // Tool-Calls werden während des Streamings nur angehängt, daher ist die
                        // Position eine stabile Identität.
                        ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                            ToolCallBadge(tool: tool)
                        }
                    }
                }

                // Thinking-Bereich – Zeigen sobald das Feld initialisiert wurde
                if let thinking = message.thinking {
                    thinkingSection(thinking, stillThinking: isStreaming && message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else if isStreaming && message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Allererste Phase: noch kein Thinking-Eintrag da, nur Leerzeichen oder nichts
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Denkt nach...")
                            .font(.caption).foregroundColor(.secondary).italic()
                    }
                }

                // Hauptinhalt
                if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    contentView

                    // Quellen-Nachweis
                    if let tools = message.toolCalls, !tools.isEmpty {
                        let sources = tools.compactMap { $0.source }.filter { !$0.isEmpty }
                        if !sources.isEmpty {
                            // Reihenfolge-Erhaltende Deduplizierung (Audit U14)
                            var seen = Set<String>()
                            let ordered = sources.filter { seen.insert($0).inserted }
                            sourcesView(sources: ordered)
                        }
                    }

                    // Aktionsleiste – erscheint erst beim Hover (Phase G)
                    if !isStreaming {
                        HStack {
                            messageActions
                                .opacity(isHovered ? 1 : 0)
                                .animation(.easeOut(duration: 0.12), value: isHovered)
                            Spacer()
                        }
                    }
                } else if isStreaming && message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && message.thinking != nil {
                    // Hat Thinking, Content kommt aber noch
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Formuliert Antwort...").font(.caption).foregroundColor(.secondary).italic()
                    }
                }

                // Fehler-Karte (Fehler-UX): eigener Fehlerzustand statt Text im Content – mit
                // direkten Retry-/Bearbeiten-Aktionen. Teilinhalt der gescheiterten Antwort
                // bleibt darüber sichtbar, wird beim nächsten Versand übersprungen.
                if let errorMessage = message.errorMessage {
                    errorCard(errorMessage)
                }
            }

            Spacer(minLength: 40)
        }
    }

    // MARK: - Fehler-Karte (Fehler-UX)

    private func errorCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.85, green: 0.35, blue: 0.2))
                Text("Antwort fehlgeschlagen")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
            }
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.s) {
                if let retry = onRetryFailed {
                    Button(action: retry) {
                        Label("Erneut versuchen", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.medium))
                    }
                    .controlSize(.regular)
                    .buttonStyle(.borderedProminent)
                    .help("Dieselbe Frage nochmal senden – mit frischem Payload")
                }
                if let rollback = onRollbackFailed {
                    Button(action: rollback) {
                        Label("Frage bearbeiten", systemImage: "square.and.pencil")
                            .font(.caption.weight(.medium))
                    }
                    .controlSize(.regular)
                    .buttonStyle(.bordered)
                    .help("Antwort und Frage zurücksetzen – der Text landet bearbeitbar im Eingabefeld")
                }
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: 460, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous).fill(Color.red.opacity(0.07)))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                .stroke(Color.red.opacity(0.15), lineWidth: 0.5)
        )
    }

    private var systemBubbleContent: some View {
        HStack {
            Spacer()
            Text(message.content)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(12)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var mainBubbleContent: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            if isUser {
                userMessageContent
            } else {
                assistantMessageContent
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .popover(item: Binding<ExplanationRequest?>(
            get: { selectedExplanation },
            set: { selectedExplanation = $0 }
        )) { text in
            InlineExplainPopover(selectedText: text.text, history: history, markedMessageId: message.id, chatViewModel: chatViewModel, fontScale: fontScale, onDismiss: {
                selectedExplanation = nil
            })
        }
    }

    // Thinking-Sektion – Eigener Aufbau statt DisclosureGroup für 100% Klick-Zuverlässigkeit auf macOS
    private func thinkingSection(_ thinking: String, stillThinking: Bool) -> some View {
        // Wortanzahl NUR nach dem Denken berechnen (O(n) split auf wachsendem Text kostet
        // während Streaming alle 200ms → exponentiell teurer je länger der Gedankengang).
        // Während stillThinking zeigen wir nur einen ungefähren Zeichencount (O(1)).
        let wordInfo: String = stillThinking
            ? "~\(thinking.utf16.count / 5) Wörter"
            : "\(thinking.split(separator: " ").count) Wörter"

        return VStack(alignment: .leading, spacing: 0) {
            // Kopfzeile als Button
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isThinkingExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isThinkingExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.blue.opacity(0.5))
                    Image(systemName: "brain.head.profile")
                        .font(.caption)

                    if stillThinking {
                        Text("Denkt nach...")
                            .font(.caption).fontWeight(.medium)
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("Gedankengang anzeigen")
                            .font(.caption).fontWeight(.medium)
                    }

                    Spacer()

                    Text(wordInfo)
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .padding(8)
                .contentShape(Rectangle())
                .foregroundColor(.blue)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            // Inhalt (ausgeklappt) – während Streaming nur die letzten 2000 Zeichen zeigen,
            // damit SwiftUI nicht den gesamten wachsenden String layouten muss.
            if isThinkingExpanded {
                let displayText = stillThinking && thinking.count > 2000
                    ? "…" + thinking.suffix(2000)
                    : thinking
                Text(displayText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.03))
                    .cornerRadius(6)
                    .padding(.bottom, 4)
            }
        }
        .padding(6)
        .background(Color.blue.opacity(0.05))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.blue.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Quellen-Nachweis (Phase 7B)
    private func sourcesView(sources: [String]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "link.circle.fill")
                .foregroundColor(.blue.opacity(0.8))
            
            ForEach(sources, id: \.self) { source in
                if let url = URL(string: source) {
                    Link(destination: url) {
                        Text(url.host ?? source)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(4)
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .help(source)
                } else {
                    Text(source)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(4)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.top, 4)
        .padding(.leading, 4)
    }

    // MARK: – Aktionsleiste (Kopieren + Andere Erklärung)
    private var messageActions: some View {
        HStack(spacing: 6) {
            // ── Kopieren ──────────────────────────────────────────────
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.content, forType: .string)
                withAnimation(.easeInOut(duration: 0.15)) { didCopy = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation(.easeInOut(duration: 0.15)) { didCopy = false }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                    if didCopy {
                        Text("Kopiert")
                            .font(.caption2)
                            .transition(.opacity)
                    }
                }
                .foregroundColor(didCopy ? .green : .secondary.opacity(0.6))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(didCopy ? Color.green.opacity(0.10) : DS.Surface.chip)
                )
                .animation(.easeInOut(duration: 0.15), value: didCopy)
            }
            .buttonStyle(.plain)
            .help("Antwort in die Zwischenablage kopieren")

            // ── Andere Erklärung ──────────────────────────────────────
            if let explain = onExplainDifferently {
                Button(action: explain) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10, weight: .medium))
                        Text("Andere Erklärung")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary.opacity(0.6))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(DS.Surface.chip))
                }
                .buttonStyle(.plain)
                .help("Erkläre mit anderer Analogie oder einem anderen Beispiel")
            }

            // ── Confidence Score ───────────────────────────────────────
            if let confidence = onCheckConfidence {
                Button(action: confidence) {
                    HStack(spacing: 4) {
                        Image(systemName: "gauge.with.needle")
                            .font(.system(size: 10, weight: .medium))
                        Text("Wie sicher?")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary.opacity(0.6))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(DS.Surface.chip))
                }
                .buttonStyle(.plain)
                .help("KI nach Konfidenz und möglichen Unsicherheiten in der Antwort fragen")
            }

            // ── Verifizieren ───────────────────────────────────────────
            if let verify = onVerify {
                Button(action: verify) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 10, weight: .medium))
                        Text("Verifizieren")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary.opacity(0.6))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(DS.Surface.chip))
                }
                .buttonStyle(.plain)
                .help("Zwingt das Modell, die Aussage per Websuche zu überprüfen")
            }

            // ── Abzweigen (Phase H) ────────────────────────────────────
            if let branch = onBranch {
                Button(action: branch) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10, weight: .medium))
                        Text("Abzweigen")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary.opacity(0.6))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(DS.Surface.chip))
                }
                .buttonStyle(.plain)
                .help("Ab hier einen eigenen Chat-Zweig starten – die Historie bis zu dieser Antwort wird kopiert")
            }

            // ── Teilen (Phase H) ───────────────────────────────────────
            // System-Share-Menü im Safari-Stil: Antwort als Markdown in Mail, Notizen,
            // AirDrop usw. – ShareLink öffnet auf macOS automatisch den NSSharingServicePicker.
            ShareLink(item: message.content, subject: Text(message.content.prefix(60))) {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 10, weight: .medium))
                    Text("Teilen")
                        .font(.caption2)
                }
                .foregroundColor(.secondary.opacity(0.6))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Capsule().fill(DS.Surface.chip))
                .help("Antwort über das System-Menü teilen (Mail, Notizen, AirDrop …)")
            }
        }
        .padding(.top, 3)
        .padding(.leading, 4)
    }

    // Hauptinhalt
    @ViewBuilder
    private var contentView: some View {
        MarkdownView(markdown: message.content, fontScale: fontScale) { text in
            self.selectedExplanation = ExplanationRequest(text: text)
        }
            .padding(isUser ? 10 : 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isUser
                          ? Color.blue.opacity(0.12)
                          : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isUser
                            ? Color.blue.opacity(0.2)
                            : Color.secondary.opacity(0.1),
                            lineWidth: 0.5)
            )
    }
}
