import SwiftUI
import AppKit

// MARK: - MessageBubble
// Nutzt Equatable, um die Re-Evaluation während des Streamings zu minimieren (Performance!).

struct MessageBubble: View, Equatable {
    static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        // Bewusst OHNE den Chatverlauf: Früher war `history` Teil der Gleichheit – da sich beim
        // Streaming die letzte Nachricht ständig ändert, galten damit ALLE Bubbles als geändert
        // und wurden alle 200 ms neu berechnet (Audit 2026-10-12, UI H1). Das InlineExplainPopover
        // liest den Verlauf jetzt beim Öffnen frisch aus dem ViewModel.
        lhs.message == rhs.message &&
        lhs.isStreaming == rhs.isStreaming &&
        lhs.isContinuation == rhs.isContinuation &&
        lhs.embedded == rhs.embedded &&
        lhs.fontScale == rhs.fontScale &&
        lhs.canRegenerate == rhs.canRegenerate
    }
    let message: ChatMessage
    /// Referenz auf den ChatViewModel (nur für das InlineExplainPopover; bewusst kein
    /// @ObservedObject – der Bubble wird über `message`/`isStreaming` Equatable-diffed,
    /// eine Beobachtung würde den Re-Render-Sturm pro Token wieder einführen (Audit U13).
    let chatViewModel: ChatViewModel
    /// Nur true für die letzte Nachricht während aktiver Generierung
    let isStreaming: Bool
    let isContinuation: Bool
    /// Teil einer Antwort-Gruppe (AssistantTurnRow): Avatar, Gedankengang und Tool-Zeilen zeigt
    /// dann die Arbeitsschritte-Gruppe – die Bubble rendert nur die Ergebnisse.
    var embedded: Bool = false
    /// Schriftgrößen-Multiplikator (Erscheinungsbild-Einstellung). Muss Teil der Equatable-Prüfung
    /// sein, sonst überspringt SwiftUIs Diffing die Neuberechnung bei einer reinen Größenänderung,
    /// wenn sich sonst nichts an der Nachricht geändert hat.
    var fontScale: Double = 1.0
    /// Letzte Antwort im Chat: „Neu generieren“ anbieten (Teil der Gleichheit, damit die Aktion
    /// beim nächsten Austausch von der alten Antwort verschwindet).
    var canRegenerate = false
    var onRegenerate: (() -> Void)? = nil
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
    @State private var didCopy = false
    struct ExplanationRequest: Identifiable { let id = UUID(); let text: String }
    @State private var selectedExplanation: ExplanationRequest? = nil

    init(
        message: ChatMessage,
        chatViewModel: ChatViewModel,
        isStreaming: Bool = false,
        isContinuation: Bool = false,
        embedded: Bool = false,
        fontScale: Double = 1.0,
        canRegenerate: Bool = false,
        onRegenerate: (() -> Void)? = nil,
        onExplainDifferently: (() -> Void)? = nil,
        onCheckConfidence: (() -> Void)? = nil,
        onVerify: (() -> Void)? = nil,
        onBranch: (() -> Void)? = nil,
        onEditFromHere: (() -> Void)? = nil,
        onRetryFailed: (() -> Void)? = nil,
        onRollbackFailed: (() -> Void)? = nil
    ) {
        self.message = message
        self.chatViewModel = chatViewModel
        self.isStreaming = isStreaming
        self.isContinuation = isContinuation
        self.embedded = embedded
        self.fontScale = fontScale
        self.canRegenerate = canRegenerate
        self.onRegenerate = onRegenerate
        self.onExplainDifferently = onExplainDifferently
        self.onCheckConfidence = onCheckConfidence
        self.onVerify = onVerify
        self.onBranch = onBranch
        self.onEditFromHere = onEditFromHere
        self.onRetryFailed = onRetryFailed
        self.onRollbackFailed = onRollbackFailed
        self._didCopy = State(initialValue: false)
    }

    private var isUser: Bool { message.role == "user" }
    
    /// Hat die Nachricht sichtbaren Inhalt (Text oder Fallback-Plots dieses Turns)?
    private var hasRenderableContent: Bool {
        if embedded {
            return WorkStep.hasAnswerText(message) || (!isStreaming && !chatViewModel.turnPlots(for: message.id).isEmpty)
        }
        return !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (!isStreaming && !chatViewModel.turnPlots(for: message.id).isEmpty)
    }

    /// Verhindert das Anzeigen von komplett leeren "Geister-Bubbles"
    private var isCompletelyEmpty: Bool {
        if embedded {
            return !hasRenderableContent && message.imageID == nil && message.htmlArtifact == nil
                && message.quizCard == nil && message.errorMessage == nil
        }
        // Ein Thought-Prozess ist NIEMALS leer
        if message.thinking != nil { return false }
        if let tools = message.toolCalls, !tools.isEmpty { return false }
        if hasRenderableContent { return false }
        if message.imageID != nil { return false }
        if message.htmlArtifact != nil { return false }
        if message.quizCard != nil { return false }
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
                .help(L("Frage im neuen Zweig bearbeiten – der bisherige Chat bleibt erhalten"))
            }
            VStack(alignment: .trailing, spacing: DS.Space.s) {
                if let imgID = message.imageID {
                    OptimizedImageView(imageID: imgID, base64: message.imageBase64)
                        .frame(maxWidth: 300)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
                }
                if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(message.displayText ?? message.content)
                        .font(.system(size: 13.5 * fontScale, design: .rounded))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s + 2)
            .background(userBubbleShape.fill(DS.Surface.bubbleUser))
            .overlay(
                userBubbleShape.stroke(DS.Accent.brand.opacity(0.14), lineWidth: 0.75)
            )
            .frame(maxWidth: 420, alignment: .trailing)
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
            if embedded {
                EmptyView()
            } else if !isContinuation {
                LernAssistBrandIcon(size: 30)
                    .padding(.top, 2)
            } else {
                Spacer().frame(width: 30)
            }

            VStack(alignment: .leading, spacing: DS.Space.s) {
                // Vom Coding-Tool erzeugte Python-Plots sind Assistenten-Artefakte. Der
                // Nutzer-Zweig renderte Bilder bereits, hier fehlte derselbe Pfad bislang –
                // dadurch war die PNG gespeichert und referenziert, aber im Chat unsichtbar.
                if let imgID = message.imageID {
                    OptimizedImageView(imageID: imgID, base64: message.imageBase64)
                        .frame(maxWidth: 720)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
                }

                // Tool-Artefakt: interaktives HTML (coding_sandbox), sandboxed direkt gerendert
                if let html = message.htmlArtifact {
                    HTMLArtifactView(
                        html: html,
                        allowedHosts: message.htmlAllowedHosts ?? [],
                        isCollapsed: message.artifactCollapsed ?? false,
                        onToggleCollapse: { chatViewModel.toggleArtifactCollapsed(messageId: message.id) },
                        fileURL: { chatViewModel.artifactFileURL(for: message) },
                        heightKey: "artifact-\(message.id)"
                    )
                }

                // Tool-Artefakt: interaktive Abfragekarte (quiz_card)
                if let card = message.quizCard {
                    QuizCardView(card: card, onAnswer: { optionIndex, freeText in
                        chatViewModel.answerQuizCard(messageId: message.id, optionIndex: optionIndex, freeText: freeText)
                    }, onRemember: { chatViewModel.rememberQuizCard(messageId: message.id) })
                }

                // Tool Calls
                if !embedded, let tools = message.toolCalls, !tools.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        // Identität über die Position, nicht über tool.id (Audit U16): Inline
                        // geparste Tool-Calls haben oft den leeren String als id – mehrere
                        // Badges mit derselben (leeren) id ließen SwiftUI die Views bei jedem
                        // Update neu zuordnen, die @State-expansion klapperte ungewollt auf/zu.
                        // Tool-Calls werden während des Streamings nur angehängt, daher ist die
                        // Position eine stabile Identität.
                        ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                            ToolActivityView(call: tool)
                        }
                    }
                }

                // Thinking-Bereich – Zeigen sobald das Feld initialisiert wurde
                if embedded {
                    EmptyView()
                } else if let thinking = message.thinking {
                    ThinkingStepRow(text: thinking, isLive: isStreaming && message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else if isStreaming && message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Allererste Phase: noch kein Thinking-Eintrag da, nur Leerzeichen oder nichts
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(L("Denkt nach..."))
                            .font(.caption).foregroundStyle(.secondary).italic()
                    }
                }

                // Hauptinhalt (eingebettet: nur echter Antworttext bzw. Fallback-Plot, Zwischenstand steht in den Schritten)
                if hasRenderableContent {
                    contentView

                    // Quellen-Nachweis
                    if !embedded, let tools = message.toolCalls, !tools.isEmpty {
                        let sources = tools.compactMap { $0.source }.filter { !$0.isEmpty }
                        if !sources.isEmpty {
                            // Reihenfolge-Erhaltende Deduplizierung (Audit U14)
                            var seen = Set<String>()
                            let ordered = sources.filter { seen.insert($0).inserted }
                            sourcesView(sources: ordered)
                        }
                    }

                    // Aktionsleiste – nur bei Hover sichtbar, Platz bleibt immer stabil reserviert
                    if !isStreaming {
                        HStack {
                            messageActions
                                .opacity(isHovered ? 1.0 : 0.0)
                                .allowsHitTesting(isHovered)
                                .animation(.easeOut(duration: 0.14), value: isHovered)
                            Spacer()
                        }
                    }
                } else if !embedded && isStreaming && message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && message.thinking != nil {
                    // Hat Thinking, Content kommt aber noch
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(L("Formuliert Antwort...")).font(.caption).foregroundStyle(.secondary).italic()
                    }
                }

                // Fehler-Karte (Fehler-UX): eigener Fehlerzustand statt Text im Content – mit
                // direkten Retry-/Bearbeiten-Aktionen. Teilinhalt der gescheiterten Antwort
                // bleibt darüber sichtbar, wird beim nächsten Versand übersprungen.
                if let errorMessage = message.errorMessage {
                    errorCard(errorMessage)
                }
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Fehler-Karte (Fehler-UX)

    private func errorCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Accent.rose)
                Text(L("Antwort fehlgeschlagen"))
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.s) {
                if let retry = onRetryFailed {
                    Button(action: retry) {
                        Label(L("Erneut versuchen"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.indigo, prominent: true))
                    .help(L("Dieselbe Frage nochmal senden – mit frischem Payload"))
                }
                if let rollback = onRollbackFailed {
                    Button(action: rollback) {
                        Label(L("Frage bearbeiten"), systemImage: "square.and.pencil")
                    }
                    .buttonStyle(SoftActionButtonStyle(tint: DS.Ink.primary))
                    .help(L("Antwort und Frage zurücksetzen – der Text landet bearbeitbar im Eingabefeld"))
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
            // Inline-Markdown (fett, `Code`, Links) statt roher Sternchen; Zeilenumbrüche bleiben
            // erhalten (z. B. /help, /tools).
            Text((try? AttributedString(markdown: message.content,
                                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                 ?? AttributedString(message.content))
                .font(.system(size: 11.5, design: .rounded))
                .multilineTextAlignment(message.content.contains("\n") ? .leading : .center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(DS.Surface.pill)
                )
                .frame(maxWidth: 560, alignment: message.content.contains("\n") ? .leading : .center)
                .foregroundStyle(.secondary)
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
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .popover(item: Binding<ExplanationRequest?>(
            get: { selectedExplanation },
            set: { selectedExplanation = $0 }
        )) { text in
            InlineExplainPopover(selectedText: text.text,
                                 history: chatViewModel.sessions.first(where: { $0.messages.contains(where: { $0.id == message.id }) })?.messages ?? [message], markedMessageId: message.id, chatViewModel: chatViewModel, fontScale: fontScale, onDismiss: {
                selectedExplanation = nil
            })
        }
    }

    // MARK: - Quellen-Nachweis (Phase 7B)
    private func sourcesView(sources: [String]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "link.circle.fill")
                .foregroundStyle(DS.Ink.accent.opacity(0.8))
            
            ForEach(sources, id: \.self) { source in
                if let url = URL(string: source) {
                    Link(destination: url) {
                        Text(url.host ?? source)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DS.Ink.accent.opacity(0.1))
                            .cornerRadius(4)
                            .foregroundStyle(DS.Ink.accent)
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
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 4)
        .padding(.leading, 4)
    }

    // MARK: – Dezente, fließende Aktionsleiste unter einer Antwort (Design 2.0)
    private var messageActions: some View {
        messageActionsRow(compact: true)
        .padding(.top, 4)
        .padding(.leading, 2)
    }

    /// Reine Quizkarten-Nachricht (ohne Text) – dort merkt die Karte selbst.
    private var embeddedQuizOnly: Bool { message.quizCard != nil && message.content.isEmpty }

    private func messageActionsRow(compact: Bool) -> some View {
        HStack(spacing: 1) {
            // ── Kopieren ──────────────────────────────────────────────
            MessageActionItem(
                icon: didCopy ? "checkmark" : "doc.on.doc",
                label: didCopy ? L("Kopiert") : L("Kopieren"),
                help: L("Antwort in die Zwischenablage kopieren"),
                alwaysShowLabel: didCopy,
                action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.content, forType: .string)
                    withAnimation(.easeInOut(duration: 0.15)) { didCopy = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation(.easeInOut(duration: 0.15)) { didCopy = false }
                    }
                }
            )

            // ── Neu generieren (nur letzte Antwort) ──────────────────
            if canRegenerate, let regenerate = onRegenerate {
                MessageActionDivider()
                MessageActionItem(
                    icon: "arrow.clockwise",
                    label: L("Neu generieren"),
                    help: L("Diese Antwort verwerfen und zur selben Frage neu erzeugen lassen"),
                    action: regenerate
                )
            }

            // ── Als Karte merken ─────────────────────────────────────
            if !embeddedQuizOnly {
                MessageActionDivider()
                MessageActionItem(
                    icon: "rectangle.on.rectangle.angled",
                    label: L("Als Karte merken"),
                    help: L("Diese Erklärung zu 1–3 Karteikarten verdichten (Panel „Karten“ → Wiederholen)"),
                    action: { chatViewModel.rememberAsFlashcards(messageId: message.id) }
                )
            }

            // ── Andere Erklärung ──────────────────────────────────────
            if let explain = onExplainDifferently {
                MessageActionDivider()
                MessageActionItem(
                    icon: "arrow.triangle.2.circlepath",
                    label: L("Andere Erklärung"),
                    help: L("Erkläre mit anderer Analogie oder einem anderen Beispiel"),
                    action: explain
                )
            }

            // ── Confidence Score ───────────────────────────────────────
            if let confidence = onCheckConfidence {
                MessageActionDivider()
                MessageActionItem(
                    icon: "gauge.with.needle",
                    label: L("Wie sicher?"),
                    help: L("KI nach Konfidenz und möglichen Unsicherheiten in der Antwort fragen"),
                    action: confidence
                )
            }

            // ── Verifizieren ───────────────────────────────────────────
            if let verify = onVerify {
                MessageActionDivider()
                MessageActionItem(
                    icon: "checkmark.seal",
                    label: L("Verifizieren"),
                    help: L("Zwingt das Modell, die Aussage per Websuche zu überprüfen"),
                    action: verify
                )
            }

            // ── Abzweigen ──────────────────────────────────────────────
            if let branch = onBranch {
                MessageActionDivider()
                MessageActionItem(
                    icon: "arrow.triangle.branch",
                    label: L("Abzweigen"),
                    help: L("Ab hier einen eigenen Chat-Zweig starten – die Historie bis zu dieser Antwort wird kopiert"),
                    action: branch
                )
            }

            // ── Teilen (rahmenlos über NSSharingServicePicker statt ShareLink-Kasten) ──
            MessageActionDivider()
            MessageShareActionItem(
                text: message.content,
                help: L("Antwort über das System-Menü teilen (Mail, Notizen, AirDrop …)")
            )

            // ── Exportieren (PDF/Markdown, z. B. Lernzettel aus /summary) ──
            MessageActionDivider()
            MessageExportActionItem(text: renderedMarkdown, rawMarkdown: message.content)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(DS.Surface.control.opacity(0.55))
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    private var renderedMarkdown: String {
        ChatViewModel.linkCitations(
            in: ChatViewModel.embedResearchImages(
                in: ChatViewModel.applyingDisplayFixes(message.content, message.displayFixes),
                images: chatViewModel.researchImages(for: message.id),
                turnPlots: chatViewModel.turnPlots(for: message.id)
            ),
            links: chatViewModel.citationLinks(for: message.id)
        )
    }

    // Hauptinhalt
    @ViewBuilder
    private var contentView: some View {
        MarkdownView(markdown: renderedMarkdown,
                     fontScale: fontScale,
                     heightKey: "\(message.id)-\(fontScale)",
                     onRepairDiagram: { source, error in
                         chatViewModel.repairDiagram(messageId: message.id, source: source, error: error)
                     }) { text in
            self.selectedExplanation = ExplanationRequest(text: text)
        }
            // Antworten als ruhiger Fließtext ohne Kasten (Phase 6): Inhalt bleibt opak und
            // lesbar, Glas gehört nur auf Bedienelemente.
            .padding(.vertical, 2)
            .padding(.horizontal, 2)
    }
}

// MARK: - Dezente Nachrichten-Aktions-Bausteine (neutral, rahmenlos, Hover-Feedback)

private struct MessageActionDivider: View {
    var body: some View {
        Circle()
            .fill(Color.primary.opacity(0.14))
            .frame(width: 2.5, height: 2.5)
            .padding(.horizontal, 2)
    }
}

/// Beschriftung eines Symbol-Knopfs als kleine Blase über (oder, nahe am oberen Fensterrand,
/// unter) dem Knopf. Sie schwebt über allem und schiebt die Leiste nicht – die Knöpfe bleiben
/// beim Entlangfahren an ihrem Platz.
private struct ActionHoverLabel: ViewModifier {
    let text: String?
    let isShown: Bool
    /// Abstand zum oberen Fensterrand; darunter ist kein Platz für die Blase nach oben.
    @State private var topInWindow: CGFloat = .infinity
    private static let minRoomAbove: CGFloat = 90

    func body(content: Content) -> some View {
        let below = topInWindow < Self.minRoomAbove
        content
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { topInWindow = $0 }
            .overlay(alignment: below ? .bottom : .top) {
                if let text, isShown {
                    Text(text)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(Color.primary.opacity(0.88))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(DS.Surface.pill)
                            .shadow(color: .black.opacity(0.14), radius: 6, y: 2))
                        .overlay(Capsule().stroke(DS.Ink.hairline, lineWidth: 0.75))
                        .alignmentGuide(below ? .bottom : .top) { d in below ? d[.top] - 5 : d[.bottom] + 5 }
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
            }
            .zIndex(isShown ? 1 : 0)
    }
}

/// Kompakter Symbol-Knopf; der Name erscheint beim Überfahren als Blase (`ActionHoverLabel`).
private struct MessageActionItem: View {
    let icon: String
    let label: String?
    let help: String
    var alwaysShowLabel = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .medium))
                .frame(minWidth: 12)
            .foregroundStyle(isHovered ? Color.primary.opacity(0.88) : Color.secondary.opacity(0.75))
            .padding(.horizontal, 6)
            .padding(.vertical, 3.5)
            .background(
                Capsule()
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(ActionHoverLabel(text: label, isShown: isHovered || alwaysShowLabel))
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering } }
        .help(help)
        .accessibilityLabel(label ?? help)
    }
}

/// Exportiert die Antwort als PDF (wie im Chat gerendert) oder Markdown.
private struct MessageExportActionItem: View {
    let text: String
    var rawMarkdown: String? = nil
    @State private var isHovered = false

    var body: some View {
        Menu {
            Button(L("Als PDF sichern …")) { StudySheetExporter.shared.exportPDF(text, suggestedName: StudySheetExporter.fileName(from: rawMarkdown ?? text)) }
            Button(L("Als Markdown sichern …")) { StudySheetExporter.shared.exportMarkdown(rawMarkdown ?? text, suggestedName: StudySheetExporter.fileName(from: rawMarkdown ?? text)) }
        } label: {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 9.5, weight: .medium))
                .frame(minWidth: 12)
            .foregroundStyle(isHovered ? Color.primary.opacity(0.88) : Color.secondary.opacity(0.75))
            .padding(.horizontal, 6)
            .padding(.vertical, 3.5)
            .background(Capsule().fill(isHovered ? Color.primary.opacity(0.08) : Color.clear))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .modifier(ActionHoverLabel(text: L("Exportieren"), isShown: isHovered))
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering } }
        .help(L("Antwort als PDF oder Markdown sichern (z. B. Lernzettel aus /summary)"))
        .accessibilityLabel(L("Exportieren"))
    }
}

private struct MessageShareActionItem: View {
    let text: String
    let help: String
    @State private var isHovered = false

    var body: some View {
        Button {
            let picker = NSSharingServicePicker(items: [text])
            if let window = NSApp.keyWindow, let contentView = window.contentView {
                let mouseLocation = window.mouseLocationOutsideOfEventStream
                let rect = NSRect(x: mouseLocation.x, y: mouseLocation.y, width: 1, height: 1)
                picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 9.5, weight: .medium))
                .frame(minWidth: 12)
            .foregroundStyle(isHovered ? Color.primary.opacity(0.88) : Color.secondary.opacity(0.75))
            .padding(.horizontal, 6)
            .padding(.vertical, 3.5)
            .background(
                Capsule()
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(ActionHoverLabel(text: L("Teilen"), isShown: isHovered))
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering } }
        .help(help)
        .accessibilityLabel(L("Teilen"))
    }
}

