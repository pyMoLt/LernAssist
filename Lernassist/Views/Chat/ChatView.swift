import SwiftUI
import AppKit

// MARK: - ChatView (Hauptansicht)

struct ChatView: View {
    @StateObject var viewModel: ChatViewModel
    @State private var inputText = ""
    @State private var lastCapturedImage: NSImage? = nil
    @State private var isShowingQuizPanel = false
    @State private var isShowingChatScreenshots = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    /// Karteikarten-/Quiz-Seed aus einem Dokument (Phase H): Wird gesetzt, wenn der Nutzer im
    /// Dokument-Badge „Karten“/„Quiz“ wählt – das Panel öffnet sich und generiert direkt daraus.
    @State private var quizPanelSeed: (text: String, mode: String)? = nil

    init(viewModel: ChatViewModel = ChatViewModel()) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // ── Sidebar ────────────────────────────────────────────
            SidebarView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 205, ideal: 235, max: 300)
        } detail: {
            // ── Detail ─────────────────────────────────────────────
            VStack(spacing: 0) {
                headerBar
                messageList
                InputArea(
                    viewModel: viewModel,
                    inputText: $inputText,
                    lastCapturedImage: $lastCapturedImage,
                    send: send,
                    enqueue: enqueue,
                    capture: captureAndSend,
                    cancel: { viewModel.cancelStreaming() },
                    addSystemMessage: { text in
                        viewModel.addSystemMessage(text: text)
                    }
                )
            }
        }
        .frame(minWidth: 400, minHeight: 400)
        .onReceive(NotificationCenter.default.publisher(for: .externalScreenshotCaptured)) { note in
            if let image = note.object as? NSImage {
                self.lastCapturedImage = image
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsRequested)) { note in
            SettingsWindowController.shared.show(viewModel: viewModel, tab: note.userInfo?["tab"] as? String)
        }
        // Systemweites "Auswahl erklären" (Phase H): Gelesene Auswahl landet als vorbereitete
        // Frage im Eingabefeld – der Nutzer kann sie noch anpassen und dann senden.
        .onReceive(NotificationCenter.default.publisher(for: .externalExplainSelection)) { note in
            if let text = note.userInfo?["text"] as? String {
                inputText = "Erkläre mir kurz und klar:\n\n„\(text)“"
            }
        }
        // "Karten"/"Quiz" aus einem Dokument-Badge (Phase H).
        .onReceive(NotificationCenter.default.publisher(for: .studyDocumentRequested)) { note in
            if let text = note.userInfo?["text"] as? String,
               let mode = note.userInfo?["mode"] as? String {
                quizPanelSeed = (text: text, mode: mode)
                isShowingQuizPanel = true
            }
        }
        .sheet(isPresented: $isShowingQuizPanel) {
            QuizFlashcardPanel(viewModel: viewModel, studySeed: quizPanelSeed)
        }
        .sheet(isPresented: $isShowingChatScreenshots) {
            ChatScreenshotPanel(viewModel: viewModel)
        }
    }

    // MARK: Header (Phase G: Liquid-Glass-Design)

    private var headerBar: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "graduationcap.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(DS.Ink.accent.gradient)
                .padding(.leading, DS.Space.m)
            headerTitleBlock
                .layoutPriority(1)
            Spacer(minLength: DS.Space.s)
            // Breite reicht nicht? Erst Beschriftungen weg (nur Symbole), dann die Metriken.
            // Vorher wurden die Chips bei 800 px mit Seitenleiste zu senkrechten Schläuchen gequetscht.
            ViewThatFits(in: .horizontal) {
                headerGlassControls(compact: false)
                headerGlassControls(compact: true)
                headerGlassControls(compact: true, showMetrics: false)
            }
            .padding(.trailing, DS.Space.m)
        }
        .frame(minHeight: 54)
        .padding(.top, DS.Space.xxs)
        // Einziger bewusstes Drag-Areal des Panels. Die Buttons im Header liegen darüber und
        // bleiben normal bedienbar; leere Header-Fläche verschiebt das Fenster per AppKit.
        .background(WindowDragHandle())
        // Header liegt auf dem Vibrancy-Fenster – KEINE opake Hintergrundfarbe mehr, sonst
        // würde der behindWindow-Blend der Panel-Fläche zerstört (Phase G).
    }

    /// Titel + Lernmodus-Schnell-Picker (Phase H): aktueller Modus unter dem Titel, ein Klick
    /// öffnet alle Modi – schneller Wechsel ohne Umweg über die Einstellungen.
    private var headerTitleBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(viewModel.activeSession?.title ?? "LernAssist")
                .font(.system(.headline, design: .rounded))
                .lineLimit(1)
            learningModeMenu
        }
    }

    private var learningModeMenu: some View {
        Menu {
            ForEach(LearningStyle.allCases, id: \.self) { style in
                Button {
                    viewModel.learningStyle = style
                    viewModel.saveSettings()
                } label: {
                    Label(style.rawValue, systemImage: style.symbol)
                }
                .disabled(style == viewModel.learningStyle)
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: viewModel.learningStyle.symbol)
                Text(viewModel.learningStyle.rawValue)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Lernmodus wechseln (wirkt auf die nächste Anfrage)")
    }

    /// Rechte Steuerseite: alle Glas-Elemente in EINEM Container – nur so sampeln verwandte
    /// Glass-Flächen konsistent (Kernregel der Liquid-Glass-Designsprache: Glass kann kein
    /// anderes Glass sampeln).
    private func headerGlassControls(compact: Bool, showMetrics: Bool = true) -> some View {
        GlassEffectContainer {
            HStack(spacing: DS.Space.s) {
                headerGlassChips(compact: compact, showMetrics: showMetrics)
                headerIconButtons
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private func headerGlassChips(compact: Bool, showMetrics: Bool) -> some View {
        // Auto-Kompakt-Angebot (Phase H): nur sichtbar, wenn der Chat lang wird.
        if viewModel.shouldSuggestCompaction {
            Button {
                viewModel.compactChat()
            } label: {
                Label("Zusammenfassen", systemImage: "sparkles")
                    .labelStyle(AdaptiveLabelStyle(compact: compact))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, DS.Space.s)
                    .padding(.vertical, DS.Space.xs)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: Capsule())
            .help("Der Chat füllt das Kontextfenster – hier zusammenfassen und als neuen Chat weiterführen")
        }

        if showMetrics {
            MetricsBar(viewModel: viewModel)
        }

        // Bilder dieses Chats
        if let session = viewModel.activeSession,
           session.messages.contains(where: { $0.imageID != nil }) {
            Button(action: { isShowingChatScreenshots = true }) {
                Label("Bilder", systemImage: "photo.stack")
                    .labelStyle(AdaptiveLabelStyle(compact: compact))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, DS.Space.s)
                    .padding(.vertical, DS.Space.xs)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: Capsule())
            .help("Zeigt alle Screenshots dieses Chats")
        }

        headerQuizChip(compact: compact)

        // Teilen (Safari-Stil, Phase H): ganzer Chat als Markdown über das System-Share-Menü.
        // Lazy (Perf-Audit K2): Der Markdown-String entsteht erst beim Klick, nicht pro Render.
        if viewModel.activeSession != nil, !(viewModel.activeSession?.messages.isEmpty ?? true) {
            GlassShareButton(
                provideItem: { [weak viewModel = viewModel] in
                    guard let viewModel, let session = viewModel.activeSession else { return "" }
                    return viewModel.chatMarkdown(for: session)
                },
                help: "Chat als Markdown teilen (Mail, Notizen, AirDrop …)"
            )
        }
    }

    /// Quiz-/Karteikarten-Chip mit Fällig-Badge (bleibt auch bei kurzen Chats sichtbar, wenn
    /// global Karteikarten fällig sind).
    @ViewBuilder
    private func headerQuizChip(compact: Bool) -> some View {
        if let session = viewModel.activeSession,
           (session.messages.count >= 2 || viewModel.dueFlashcardsCount > 0),
           !viewModel.isStreaming {
            Button(action: { isShowingQuizPanel = true; quizPanelSeed = nil }) {
                HStack(spacing: DS.Space.xxs) {
                    Label("Quiz", systemImage: "checkmark.circle.badge.questionmark")
                        .labelStyle(AdaptiveLabelStyle(compact: compact))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                    if viewModel.dueFlashcardsCount > 0 {
                        Text("\(min(viewModel.dueFlashcardsCount, 99))")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.red))
                    }
                }
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, DS.Space.xs)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: Capsule())
            .help(viewModel.dueFlashcardsCount > 0
                  ? "Öffnet das Quiz- & Karteikarten-Panel — \(viewModel.dueFlashcardsCount) Karte(n) fällig"
                  : "Öffnet das Quiz- & Karteikarten-Panel für die besprochenen Themen")
        }
    }

    @ViewBuilder
    private var headerIconButtons: some View {
        GlassIconButton(systemImage: "sidebar.left", help: "Sidebar ein-/ausblenden") {
            NotificationCenter.default.post(name: .toggleSidebar, object: nil)
        }
        GlassIconButton(systemImage: "slider.horizontal.3", help: "Einstellungen öffnen") {
            SettingsWindowController.shared.show(viewModel: viewModel, tab: nil)
        }
    }

    // MARK: Nachrichtenliste

    // true wenn der User ABSICHTLICH nach oben gescrollt hat (via LiveScroll-Event).
    // Wird via ScrollBottomDetector.onUserScroll gesetzt – unterscheidet echten
    // User-Scroll von programmatischen proxy.scrollTo-Aufrufen.
    @State private var userScrolledUp = false

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // VStack statt LazyVStack: Hält alle WKWebView-Instanzen am Leben.
                // LazyVStack crasht auf macOS bei asynchronen Höhen-Updates von NSViewRepresentables (EXC_BREAKPOINT).
                // Der WebViewPool wird für die existierenden WebViews beim Dismanteln trotzdem verwendet!
                VStack(alignment: .leading, spacing: 28) {
                    if let session = viewModel.activeSession {
                        let messagesToShow = session.messages.filter { $0.role != "tool" }

                        if messagesToShow.isEmpty {
                            emptyChatState
                        } else {
                            ForEach(Array(messagesToShow.enumerated()), id: \.element.id) { idx, message in
                            // MessageRow als eigenes Struct: Entlastet den Type-Checker, der
                            // den kompletten Inline-Body (viele bedingte Closures) nicht mehr
                            // in angemessener Zeit prüfen konnte.
                            MessageRow(
                                viewModel: viewModel,
                                message: message,
                                messages: messagesToShow,
                                isLast: idx == messagesToShow.indices.last,
                                prevMessage: idx > 0 ? messagesToShow[idx - 1] : nil,
                                isStreaming: viewModel.isStreaming,
                                fontScale: viewModel.chatFontSize,
                                userScrolledUp: $userScrolledUp,
                                onEditFromUserMessage: { msg in
                                    userScrolledUp = false
                                    if let text = viewModel.branchFromUserMessageForEditing(id: msg.id) {
                                        inputText = text
                                    }
                                },
                                onRetryFailed: { msg in
                                    userScrolledUp = false
                                    viewModel.retryFailedExchange(assistantMessageId: msg.id)
                                },
                                onRollbackFailed: { msg in
                                    userScrolledUp = false
                                    if let text = viewModel.rollbackFailedExchange(assistantMessageId: msg.id) {
                                        inputText = text
                                    }
                                }
                            )
                            }
                        }
                    }
                    // Scroll-Anker
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 12)
                // Auch im Vollbild bleibt der Dialog eine zusammenhängende Spalte:
                // Nutzer-Bubbles rechts und Assistenten-Inhalte links innerhalb derselben
                // lesbaren Breite, statt an entgegengesetzten Fensterrändern zu kleben.
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                // ScrollBottomDetector als Background des VStack – INNERHALB des ScrollView.
                // Nur so liegt _ScrollDetectorView im Document View des NSScrollView und
                // kann via superview-Traversal den NSScrollView finden.
                // Als .background() auf dem ScrollView selbst wäre es ein Geschwister-View
                // des NSScrollView → attachToScrollView() würde ihn nie finden.
                .background(ScrollBottomDetector(
                    onScrolled: {
                        userScrolledUp = true
                    },
                    onScrollEnded: { atBottom in
                        if atBottom { userScrolledUp = false }
                    }
                ))
            }
            // Phase G: Nachrichten-Fläche als Material – Chat-Text bleibt lesbar, das
            // Vibrancy-Fenster dahinter schimmert dezent durch (Glass-Regel: Steuerflächen
            // aus Glass, Content auf ruhiger, leicht transluzenter Fläche).
            .background(.thinMaterial)
            .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
                withAnimation {
                    columnVisibility = (columnVisibility == .all) ? .detailOnly : .all
                }
            }
            // Auto-Scroll nur wenn User NICHT nach oben gescrollt hat
            .onChange(of: viewModel.activeSession?.messages.last?.content) { _ in
                if !userScrolledUp { debouncedScrollToBottom(proxy: proxy) }
            }
            .onChange(of: viewModel.activeSession?.messages.last?.thinking) { _ in
                if !userScrolledUp { debouncedScrollToBottom(proxy: proxy) }
            }
            .onChange(of: viewModel.activeSession?.messages.count) { _ in
                if !userScrolledUp { debouncedScrollToBottom(proxy: proxy) }
            }
            .onChange(of: viewModel.isStreaming) { streaming in
                // Streaming beendet → nur scrollen wenn User NICHT hochgescrollt hat.
                // userScrolledUp wird hier NICHT zurückgesetzt – nur send() darf das.
                // (Fix: Tool-Call-Zyklen triggerten diesen Handler mehrfach und
                //  zogen den User jedes Mal ans Ende zurück.)
                if !streaming && !userScrolledUp {
                    scrollToBottom(proxy: proxy, animated: true)
                }
            }
        }
    }

    /// Ruhiger Startzustand statt einer leeren Chat-Fläche. Die Vorschläge setzen nur den
    /// Eingabetext; gesendet wird weiterhin ausschließlich durch die übliche Senden-Aktion.
    private var emptyChatState: some View {
        VStack(spacing: DS.Space.l) {
            ZStack {
                Circle()
                    .fill(DS.Ink.accent.opacity(0.12))
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(DS.Ink.accent.gradient)
            }
            .frame(width: 68, height: 68)

            VStack(spacing: DS.Space.xs) {
                Text("Womit möchtest du lernen?")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                Text("Stelle eine Frage, füge einen Screenshot hinzu oder wähle einen Startpunkt.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Grid(horizontalSpacing: DS.Space.s, verticalSpacing: DS.Space.s) {
                GridRow {
                    welcomePrompt("Screenshot aufnehmen", icon: "camera.viewfinder", action: captureAndSend)
                    welcomePrompt("Einfach erklären", icon: "text.book.closed", text: "Erkläre mir dieses Thema einfach und mit einem Beispiel:")
                    welcomePrompt("Lernplan erstellen", icon: "calendar.badge.plus", text: "Erstelle mir einen kurzen Lernplan für:")
                }
                GridRow {
                    welcomePrompt("Mich abfragen", icon: "checkmark.circle", text: "/quiz ")
                    welcomePrompt("Diagramm", icon: "chart.xyaxis.line", text: "/diagram ")
                    welcomePrompt("Zusammenfassen", icon: "list.bullet.rectangle", text: "/summary ")
                }
            }
        }
        .padding(DS.Space.xxl)
        .frame(maxWidth: 610)
        .frame(maxWidth: .infinity, minHeight: 330)
    }

    private func welcomePrompt(_ title: String, icon: String, text: String = "", action: (() -> Void)? = nil) -> some View {
        Button {
            if let action { action() } else { inputText = text }
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DS.Ink.accent)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
            .padding(DS.Space.m)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                    .fill(DS.Surface.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                    .stroke(DS.Ink.hairline.opacity(0.55), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("Setzt eine Vorlage ins Eingabefeld")
    }

    // Rate-limiting für automatisches Scrollen (max alle 100ms)
    @State private var lastScrollTime: Date = .distantPast

    private func debouncedScrollToBottom(proxy: ScrollViewProxy) {
        guard viewModel.isStreaming else { return }
        let now = Date()
        if now.timeIntervalSince(lastScrollTime) > 0.15 {
            lastScrollTime = now
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    // MARK: Aktionen

    // Hinweis: Slash-Befehle (/compact, /clear, /model, ...) werden bereits von
    // InputArea.handleSend() über die SlashCommandRegistry abgefangen, BEVOR send() hier
    // überhaupt aufgerufen wird. send() sieht daher nie einen "/"-Text — es gab hier zuvor
    // eine zweite, redundante und mit der Registry inkonsistente /compact-/clear-/help-
    // Behandlung (toter Code, nie erreicht), die entfernt wurde.
    func send() {
        guard !inputText.isEmpty || lastCapturedImage != nil else { return }
        let text = inputText.isEmpty ? "Was ist auf diesem Screenshot zu sehen? Erkläre es mir." : inputText

        let imageToEncode = lastCapturedImage
        inputText = ""
        lastCapturedImage = nil
        userScrolledUp = false
        performSend(text: text, image: imageToEncode)
    }

    /// Vertikale Einrückung von Fortsetzungs-Nachrichten (Assistant nach Assistant).
    /// Als Helper statt Ternary-Kaskade im View-Body: entlastet den Type-Checker.
    static func continuationPadding(isContinuation: Bool, prevWasToolOnly: Bool) -> CGFloat {
        if !isContinuation { return 0 }
        return prevWasToolOnly ? -32 : -20
    }

    private func performSend(text: String, image: NSImage?) {
        Task {
            let base64 = await Task.detached(priority: .userInitiated) {
                image.flatMap { ScreenshotManager.shared.imageToBase64($0) }
            }.value
            await MainActor.run {
                viewModel.sendMessage(text: text, imageBase64: base64)
            }
        }
    }

    /// Stellt die aktuelle Eingabe (Text und/oder Screenshot) in die Warteschlange, statt sie
    /// sofort zu senden – für Folgefragen, während das Modell noch an der vorherigen Antwort
    /// generiert. Wird automatisch nachgereicht, sobald `viewModel.isStreaming` auf false wechselt.
    func enqueue() {
        guard !inputText.isEmpty || lastCapturedImage != nil else { return }
        let text = inputText.isEmpty ? "Was ist auf diesem Screenshot zu sehen? Erkläre es mir." : inputText

        let imageToEncode = lastCapturedImage
        inputText = ""
        lastCapturedImage = nil

        Task {
            let base64 = await Task.detached(priority: .userInitiated) {
                imageToEncode.flatMap { ScreenshotManager.shared.imageToBase64($0) }
            }.value
            await MainActor.run {
                viewModel.enqueueMessage(text: text, imageBase64: base64)
            }
        }
    }

    func captureAndSend() {
        ScreenshotManager.shared.captureScreenshot { image in
            if let image = image {
                DispatchQueue.main.async { self.lastCapturedImage = image }
            }
        }
    }
}

// MARK: - MessageRow (Phase G)
//
// Eine Zeile der Nachrichtenliste als eigenes Struct: Entlastet den Type-Checker (der
// komplette Inline-Body mit vielen bedingten Closures war nicht mehr in angemessener
// Zeit prüfbar) und hält die Listen-Logik neben der Scroll-Logik.

private struct MessageRow: View {
    let viewModel: ChatViewModel
    let message: ChatMessage
    /// Allen Rows dieselbe Array-Instanz statt pro Row einer O(n)-Prefix-Kopie (Audit U4).
    let messages: [ChatMessage]
    let isLast: Bool
    let prevMessage: ChatMessage?
    let isStreaming: Bool
    let fontScale: Double
    @Binding var userScrolledUp: Bool
    // Fehler-UX (Phase Retry): Aktionen, die den Chat-Zustand + das Eingabefeld der ChatView brauchen.
    let onEditFromUserMessage: (ChatMessage) -> Void
    let onRetryFailed: (ChatMessage) -> Void
    let onRollbackFailed: (ChatMessage) -> Void

    private var isContinuation: Bool {
        prevMessage?.role == message.role && message.role == "assistant"
    }

    /// Vertikale Einrückung von Fortsetzungs-Nachrichten (Assistant nach Assistant).
    private var extraPadding: CGFloat {
        if !isContinuation { return 0 }
        let prevWasToolOnly = prevMessage?.role == "assistant"
            && (prevMessage?.content.isEmpty ?? false)
            && !(prevMessage?.toolCalls?.isEmpty ?? true)
        return prevWasToolOnly ? -32 : -20
    }

    var body: some View {
        Group {
            if message.role == "document" {
                DocumentBadgeView(message: message)
                    .padding(.horizontal, 10)
                    .padding(.top, extraPadding)
                    .id(message.id)
            } else {
                MessageBubble(
                    message: message,
                    chatViewModel: viewModel,
                    isStreaming: isStreaming && isLast,
                    isContinuation: isContinuation,
                    fontScale: fontScale,
                    onExplainDifferently: message.role == "assistant" ? {
                        userScrolledUp = false
                        viewModel.sendMessage(
                            text: "Erkläre das gerade Erklärte nochmal auf eine andere Art – " +
                                  "nutze eine andere Analogie, ein anderes Beispiel oder einen anderen Blickwinkel."
                        )
                    } : nil,
                    onCheckConfidence: message.role == "assistant" ? {
                        userScrolledUp = false
                        viewModel.sendMessage(text: """
                            Reflektiere kritisch über deine letzte Antwort und schätze deine Konfidenz ein.

                            Gehe dabei so vor:
                            1. Identifiziere die einzelnen Kernaussagen deiner Antwort.
                            2. Ordne jede Aussage einer dieser Kategorien zu:
                               - ✅ **Sicher** – gut etabliertes, stabiles Wissen
                               - ⚠️ **Mittel** – plausibel, aber möglicherweise veraltet, vereinfacht oder kontextabhängig
                               - ❌ **Unsicher** – Spekulation, außerhalb meines verlässlichen Wissens, oder schwer überprüfbar
                            3. Erkläre kurz, *warum* du die Einordnung so vorgenommen hast.
                            4. Nenne konkret, was der Nutzer unbedingt nochmal selbst verifizieren sollte.

                            Sei dabei ehrlich – ein „Ich weiß das nicht mit Sicherheit“ ist wertvoller als eine falsche Gewissheit.
                            """)
                    } : nil,
                    onVerify: message.role == "assistant" ? {
                        userScrolledUp = false
                        viewModel.verifyLastResponse()
                    } : nil,
                    // Chat-Branching (Phase H, Audit M4): Während einer laufenden Antwort deaktiviert,
                    // damit nicht eine partielle, noch schreibende Antwort als Zweig kopiert wird.
                    onBranch: message.role == "assistant" && !isStreaming ? {
                        viewModel.branchFromMessage(id: message.id)
                    } : nil,
                    // Fehler-UX: Rollback/Bearbeiten für Nutzer-Nachrichten, Retry/Rollback für
                    // fehlgeschlagene Antworten.
                    onEditFromHere: message.role == "user" ? {
                        onEditFromUserMessage(message)
                    } : nil,
                    onRetryFailed: message.role == "assistant" ? {
                        onRetryFailed(message)
                    } : nil,
                    onRollbackFailed: message.role == "assistant" ? {
                        onRollbackFailed(message)
                    } : nil
                )
                // .equatable() ist PFLICHT (Perf-Audit K1): SwiftUI konsultiert die ==
                // Implementierung von MessageBubble NUR mit diesem Modifier. Ohne ihn wurde
                // der Body jedes Bubbles bei jedem Token-Batch re-evaluiert – der dokumentierte
                // Diffing-Schutz existierte faktisch nicht.
                .equatable()
                .id(message.id)
                .padding(.top, extraPadding)
            }
        }
    }
}

/// Label mit Text, im kompakten Header nur das Symbol.
struct AdaptiveLabelStyle: LabelStyle {
    let compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.icon
        } else {
            HStack(spacing: 4) { configuration.icon; configuration.title }
        }
    }
}
