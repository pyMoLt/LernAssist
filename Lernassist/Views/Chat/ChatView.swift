import SwiftUI
import AppKit

// MARK: - ChatView (Hauptansicht)

struct ChatView: View {
    @StateObject var viewModel: ChatViewModel
    @ObservedObject private var connectionWatch = ConnectionWatch.shared
    @State private var inputText = ""
    @State private var lastCapturedImage: NSImage? = nil
    @State private var isShowingQuizPanel = false
    @State private var isShowingChatScreenshots = false
    @State private var isSidebarVisible = true
    @State private var isFindVisible = false
    @State private var findQuery = ""
    @State private var findIndex = 0
    /// Karteikarten-/Quiz-Seed aus einem Dokument (Phase H): Wird gesetzt, wenn der Nutzer im
    /// Dokument-Badge „Karten“/„Quiz“ wählt – das Panel öffnet sich und generiert direkt daraus.
    @State private var quizPanelSeed: (text: String, mode: String)? = nil

    init(viewModel: ChatViewModel = ChatViewModel()) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        // Version 4: eigenes Layout statt NavigationSplitView – die Seitenleiste schwebt als Karte
        // über dem Farbfeld (Vorlage), ohne die graue System-Fläche der Split-Ansicht.
        HStack(spacing: 0) {
            if isSidebarVisible {
                // Breite in eigener Ansicht (SidebarColumn): Beim Ziehen wird nur sie neu aufgebaut,
                // nicht die ganze Chat-Ansicht.
                SidebarColumn(viewModel: viewModel)
                    .ignoresSafeArea(.container, edges: .top)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                SidebarResizeHandle(isVisible: $isSidebarVisible)
                    .ignoresSafeArea(.container, edges: .top)
            }
            // ── Detail (Durchgehendes Flowing Canvas) ──────────────
            VStack(spacing: 0) {
                headerBar
                messageList
                    .overlay(alignment: .bottom) {
                        if let notice = viewModel.flashcardNotice {
                            FlashcardNoticeView(notice: notice,
                                                onShow: { viewModel.flashcardNotice = nil; quizPanelSeed = nil; isShowingQuizPanel = true },
                                                onUndo: { viewModel.undoFlashcardNotice(notice) },
                                                onDismiss: { if viewModel.flashcardNotice?.id == notice.id { viewModel.flashcardNotice = nil } })
                                .padding(.bottom, DS.Space.s)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                                .id(notice.id)
                        }
                    }
                    .animation(.snappy(duration: 0.25), value: viewModel.flashcardNotice)
                    .overlay(alignment: .top) {
                        if let issue = connectionWatch.issues.first {
                            ConnectionIssueBanner(issue: issue,
                                                  moreCount: connectionWatch.issues.count - 1,
                                                  onOpenSettings: {
                                                      SettingsWindowController.shared.show(viewModel: viewModel, tab: issue.settingsTab)
                                                  },
                                                  onDismiss: { connectionWatch.dismiss(issue) })
                                .padding(.top, DS.Space.s)
                                .padding(.horizontal, DS.Space.l)
                                .transition(.move(edge: .top).combined(with: .opacity))
                                .id(issue.id)
                        }
                    }
                    .animation(.snappy(duration: 0.25), value: connectionWatch.issues)
                    .task { connectionWatch.start(viewModel: viewModel) }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .leading) {
                if !isSidebarVisible {
                    SidebarEdgePullZone(isVisible: $isSidebarVisible)
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: isSidebarVisible)
        .background {
            ColorFieldBackground(accent: viewModel.appearance.accent, background: viewModel.appearance.background)
        }
        .appAppearance(viewModel.appearance, language: viewModel.appLanguage)
        .frame(minWidth: 400, minHeight: 400)
        .onReceive(NotificationCenter.default.publisher(for: .externalScreenshotCaptured)) { note in
            if let image = note.object as? NSImage {
                self.lastCapturedImage = image
            }
        }
        // „Reparieren lassen“ an einem Tool-Schritt: Fehler an das Modell schicken.
        .onReceive(NotificationCenter.default.publisher(for: .repairRequested)) { note in
            guard let text = note.userInfo?["text"] as? String, !viewModel.isStreaming else { return }
            userScrolledUp = false
            viewModel.sendMessage(text: text, displayText: L("Reparieren lassen"))
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
                if mode == "flashcards" {
                    quizPanelSeed = (text: text, mode: mode)
                    isShowingQuizPanel = true
                } else {
                    // Abfragen läuft im Chat (Quizkarten), nicht mehr in einem eigenen Panel.
                    viewModel.sendMessage(
                        text: "Frag mich zu diesem Dokument ab: Stelle nacheinander 5 Fragen, jede als `quiz_card`, warte jeweils auf meine Antwort und gib kurzes Feedback.\n\nDokumentauszug:\n" + String(text.prefix(8_000)),
                        displayText: "/quiz 5 (Dokument)")
                }
            }
        }
        .sheet(isPresented: $isShowingQuizPanel) {
            FlashcardsPanel(viewModel: viewModel, documentSeed: quizPanelSeed?.text)
        }
        .sheet(isPresented: $isShowingChatScreenshots) {
            ChatScreenshotPanel(viewModel: viewModel)
        }
    }

    // MARK: Header (Zweistufig: Volle Breite für den Titel oben, darunter Lernmodus & Live-Telemetrie)

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            // 1. Obere Zeile: Feinerer Chat-Titel über die gesamte Fensterbreite (kein frühes Abschneiden!)
            HStack(spacing: 7) {
                LernAssistBrandIcon(size: 20)
                Text(viewModel.activeSession?.displayTitle ?? L("LernAssist"))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Ink.primary.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 2. Untere Zeile: Links Lernmodus-Pill, rechts Live-Telemetrie-Kapsel & Aktionen
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.s) {
                    learningModeMenu(shortLabel: false)
                    Spacer(minLength: DS.Space.xs)
                    headerControls(compact: false)
                }
                HStack(spacing: DS.Space.xs) {
                    learningModeMenu(shortLabel: true)
                    Spacer(minLength: DS.Space.xs)
                    headerControls(compact: true)
                }
                // Schmal: Telemetrie nur als Zahlen (Prefill · Decode), ganz schmal ohne.
                HStack(spacing: DS.Space.xs) {
                    learningModeMenu(shortLabel: true)
                    Spacer(minLength: DS.Space.xs)
                    headerControls(compact: true, metrics: .compact)
                }
                HStack(spacing: DS.Space.xs) {
                    learningModeMenu(shortLabel: true)
                    Spacer(minLength: DS.Space.xs)
                    headerControls(compact: true, metrics: .hidden)
                }
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(WindowDragHandle())
    }

    private var learningModeColor: Color {
        switch viewModel.learningStyle {
        case .beginner: return DS.Accent.emerald
        case .detailed: return DS.Accent.brand
        case .exam:     return DS.Accent.amber
        case .socratic: return DS.Accent.rose
        case .tutor:    return DS.Accent.blue
        case .compact:  return DS.Accent.cyan
        case .visual:   return DS.Accent.cyan
        }
    }

    private func learningModeMenu(shortLabel: Bool = false) -> some View {
        let fullText = L(dynamic: viewModel.learningStyle.rawValue)
        let shortText = fullText.components(separatedBy: " ").first ?? fullText
        return Menu {
            ForEach(LearningStyle.allCases, id: \.self) { style in
                Button {
                    viewModel.learningStyle = style
                    viewModel.saveSettings()
                } label: {
                    if style == viewModel.learningStyle {
                        Label(L(dynamic: style.rawValue), systemImage: "checkmark")
                    } else {
                        Label(L(dynamic: style.rawValue), systemImage: style.symbol)
                    }
                }
            }
        } label: {
            GlassChip {
                HStack(spacing: 5) {
                    Image(systemName: viewModel.learningStyle.symbol)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(learningModeColor)
                    Text(shortLabel ? shortText : fullText)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(L("Lernmodus wechseln (wirkt auf die nächste Anfrage)"))
        .accessibilityLabel(L("Lernmodus: \(viewModel.learningStyle.rawValue)"))
    }

    enum MetricsMode { case full, compact, hidden }

    private func headerControls(compact: Bool, metrics: MetricsMode = .full) -> some View {
        HStack(spacing: DS.Space.s) {
            headerChips(compact: compact, metrics: metrics)
            headerActionCluster
        }
        .fixedSize()
    }

    @ViewBuilder
    private func headerChips(compact: Bool, metrics: MetricsMode) -> some View {
        if viewModel.shouldSuggestCompaction {
            Button {
                viewModel.compactChat()
            } label: {
                GlassChip {
                    Label(L("Zusammenfassen"), systemImage: "sparkles")
                        .labelStyle(AdaptiveLabelStyle(compact: compact))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(DS.Accent.amber)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
            }
            .buttonStyle(.plain)
            .help(L("Der Chat füllt das Kontextfenster – hier zusammenfassen und als neuen Chat weiterführen"))
        }

        if metrics != .hidden {
            MetricsBar(viewModel: viewModel, telemetry: viewModel.telemetry, compact: metrics == .compact)
        }

        if let session = viewModel.activeSession,
           session.messages.contains(where: { $0.imageID != nil }) {
            Button(action: { isShowingChatScreenshots = true }) {
                GlassChip {
                    Label(L("Bilder"), systemImage: "photo.stack")
                        .labelStyle(AdaptiveLabelStyle(compact: compact))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(DS.Accent.cyan)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
            }
            .buttonStyle(.plain)
            .help(L("Zeigt alle Screenshots dieses Chats"))
        }

        headerQuizChip(compact: compact)
    }

    /// Karteikarten-Chip mit Fällig-Badge.
    @ViewBuilder
    private func headerQuizChip(compact: Bool) -> some View {
        if viewModel.activeSession != nil, !viewModel.isStreaming {
            Button(action: { isShowingQuizPanel = true; quizPanelSeed = nil }) {
                GlassChip {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.on.rectangle.angled")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DS.Ink.accent)
                        if !compact {
                            Text(L("Karten"))
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.primary)
                        }
                        if viewModel.dueFlashcardsCount > 0 {
                            Text("\(min(viewModel.dueFlashcardsCount, 99))")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(DS.Ink.accent))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                }
            }
            .buttonStyle(.plain)
            .help(viewModel.dueFlashcardsCount > 0
                  ? "Karteikarten – \(viewModel.dueFlashcardsCount) fällig"
                  : "Karteikarten ansehen, anlegen und wiederholen")
            .accessibilityLabel(viewModel.dueFlashcardsCount > 0 ? L("Karteikarten, \(viewModel.dueFlashcardsCount) fällig") : L("Karteikarten"))
        }
    }

    /// Gebündelte Action-Kapsel rechts im Header (statt einzelner schwarz umrandeter Kreise).
    private var headerActionCluster: some View {
        GlassChip {
            HStack(spacing: 2) {
                if viewModel.activeSession != nil, !(viewModel.activeSession?.messages.isEmpty ?? true) {
                    GlassShareButton(
                        provideItem: { [weak viewModel = viewModel] in
                            guard let viewModel, let session = viewModel.activeSession else { return "" }
                            return viewModel.chatMarkdown(for: session)
                        },
                        help: L("Chat als Markdown teilen (Mail, Notizen, AirDrop …)")
                    )
                }

                GlassIconButton(systemImage: "sidebar.left", help: L("Sidebar ein-/ausblenden")) {
                    NotificationCenter.default.post(name: .toggleSidebar, object: nil)
                }

                GlassIconButton(systemImage: "slider.horizontal.3", help: L("Einstellungen öffnen")) {
                    SettingsWindowController.shared.show(viewModel: viewModel, tab: nil)
                }
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
        }
    }

    // MARK: Nachrichtenliste

    @State private var userScrolledUp = false

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy (Version 4): Bei langen Chats entstehen nur die sichtbaren Zeilen – vorher
                // hielt jeder Chat für jede Antwort eine eigene Web-Ansicht im Speicher.
                LazyVStack(alignment: .leading, spacing: 26) {
                    Color.clear.frame(height: 0).id("top")
                    if let session = viewModel.activeSession {
                        let messagesToShow = session.messages.filter { $0.role != "tool" }

                        if messagesToShow.isEmpty {
                            emptyChatState
                        } else {
                            let items = ChatRowItem.items(from: messagesToShow)
                            ForEach(items) { item in
                                switch item {
                                case .turn(let turn):
                                    AssistantTurnRow(
                                        messages: turn,
                                        isRunning: viewModel.isStreaming && item.id == items.last?.id,
                                        row: { message, isLastInTurn in
                                            messageRow(message, isLast: isLastInTurn && item.id == items.last?.id,
                                                       prevMessage: nil, embedded: true)
                                        }
                                    )
                                    .id(item.id)
                                case .single(let message):
                                    messageRow(message, isLast: item.id == items.last?.id,
                                               prevMessage: nil, embedded: false)
                                }
                            }
                        }
                    } else {
                        emptyChatState
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }

                .padding(.vertical, 16)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 22)
                .background(ScrollBottomDetector(
                    onScrolled: {
                        userScrolledUp = true
                    },
                    onScrollEnded: { atBottom in
                        if atBottom { userScrolledUp = false }
                    }
                ))
            }
            // Sanftes Ein-/Ausblenden oben und unten am Übergang zu Header und Composer
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [.clear, .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 12)
                    Color.black
                    LinearGradient(
                        colors: [.black, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 14)
                }
            )
            // „Zum Ende“: erscheint, sobald man im Verlauf nach oben gescrollt hat.
            .overlay(alignment: .bottomTrailing) {
                if userScrolledUp, !(viewModel.activeSession?.messages.isEmpty ?? true) {
                    Button {
                        userScrolledUp = false
                        scrollToBottom(proxy: proxy, animated: true)
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DS.Ink.accent)
                            .frame(width: 32, height: 32)
                            .glassSurface(Circle(), elevated: true)
                    }
                    .buttonStyle(.plain)
                    .help(L("Zum Ende des Chats"))
                    .accessibilityLabel(L("Zum Ende des Chats"))
                    .padding(.trailing, 26)
                    .padding(.bottom, 14)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.2), value: userScrolledUp)
            // Suche im Chat (⌘F)
            .overlay(alignment: .top) {
                if isFindVisible {
                    let items = ChatRowItem.items(from: (viewModel.activeSession?.messages ?? []).filter { $0.role != "tool" })
                    ChatFindBar(query: $findQuery,
                                matches: ChatFindBar.matches(for: findQuery, in: items),
                                current: $findIndex,
                                onJump: { id in
                                    userScrolledUp = true
                                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .top) }
                                },
                                onClose: { isFindVisible = false; findQuery = "" })
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .findInChat)) { _ in
                withAnimation(.snappy(duration: 0.2)) { isFindVisible = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
                withAnimation(.snappy(duration: 0.25)) { isSidebarVisible.toggle() }
            }
            .onChange(of: viewModel.activeSession?.messages.last?.content) { _, _ in
                if !userScrolledUp { debouncedScrollToBottom(proxy: proxy) }
            }
            .onChange(of: viewModel.activeSession?.messages.last?.thinking) { _, _ in
                if !userScrolledUp { debouncedScrollToBottom(proxy: proxy) }
            }
            .onChange(of: viewModel.activeSession?.messages.count) { _, _ in
                // Eigene neue Nachricht (auch über Slash-Befehle, Quizkarten, Startkarten):
                // immer ans Ende springen, selbst wenn vorher hochgescrollt war.
                if viewModel.activeSession?.messages.last?.role == "user" {
                    userScrolledUp = false
                    scrollToBottom(proxy: proxy, animated: true)
                } else if !userScrolledUp {
                    debouncedScrollToBottom(proxy: proxy)
                }
            }
            .onChange(of: viewModel.activeSessionId) { _, _ in
                // Chatwechsel: Scrollposition des vorherigen Chats nicht übernehmen.
                userScrolledUp = false
                DispatchQueue.main.async {
                    if viewModel.activeSession?.messages.isEmpty ?? true {
                        proxy.scrollTo("top", anchor: .top)
                    } else {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.isStreaming) { _, streaming in
                if !streaming && !userScrolledUp {
                    scrollToBottom(proxy: proxy, animated: true)
                }
            }
        }
    }

    /// Ruhiger, moderner Startzustand mit dem neuen LernAssist-App-Icon und farblich akzentuierten Startkarten.
    private var emptyChatState: some View {
        VStack(spacing: DS.Space.l + 4) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [DS.Accent.brand.opacity(0.18), Color.clear],
                            center: .center,
                            startRadius: 4,
                            endRadius: 52
                        )
                    )
                    .frame(width: 96, height: 96)

                LernAssistBrandIcon(size: 62)
            }

            VStack(spacing: DS.Space.xs + 2) {
                Text(L("Womit möchtest du lernen?"))
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                Text(L("Stelle eine Frage, füge einen Screenshot hinzu oder wähle einen Startpunkt."))
                    .font(.system(size: 13.5, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Grid(horizontalSpacing: DS.Space.m, verticalSpacing: DS.Space.m) {
                GridRow {
                    welcomePrompt(L("Screenshot"), subtitle: L("Bereich erklären lassen"), icon: "camera.viewfinder", tint: DS.Accent.brand, action: captureAndSend)
                    welcomePrompt(L("Einfach erklären"), subtitle: L("Mit Alltagsbeispiel"), icon: "text.book.closed.fill", tint: DS.Accent.emerald, text: L("Erkläre mir dieses Thema einfach und mit einem Beispiel:"))
                    welcomePrompt(L("Lernplan erstellen"), subtitle: L("Strukturierte Schritte"), icon: "calendar.badge.plus", tint: DS.Accent.blue, text: L("Erstelle mir einen kurzen Lernplan für:"))
                }
                GridRow {
                    welcomePrompt(L("Mich abfragen"), subtitle: L("Interaktives Quiz"), icon: "checkmark.seal.fill", tint: DS.Accent.rose, text: L("/quiz "))
                    welcomePrompt(L("Diagramm"), subtitle: L("Ablauf visualisieren"), icon: "chart.xyaxis.line", tint: DS.Accent.cyan, text: L("/diagram "))
                    welcomePrompt(L("Zusammenfassen"), subtitle: L("Kernaussagen kompakt"), icon: "list.bullet.rectangle.portrait.fill", tint: DS.Accent.amber, text: L("/summary "))
                }
            }
        }
        .padding(.vertical, DS.Space.xxl)
        .padding(.horizontal, DS.Space.l)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, minHeight: 350)
    }

    private func welcomePrompt(
        _ title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        text: String = "",
        action: (() -> Void)? = nil
    ) -> some View {
        WelcomeCardButton(title: title, subtitle: subtitle, icon: icon, tint: tint) {
            if let action { action() } else { inputText = text }
        }
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

    /// Eine Nachrichtenzeile mit allen Aktionen (Bearbeiten, Retry, Rollback).
    private func messageRow(_ message: ChatMessage, isLast: Bool, prevMessage: ChatMessage?, embedded: Bool) -> some View {
        MessageRow(
            viewModel: viewModel,
            message: message,
            isLast: isLast,
            prevMessage: prevMessage,
            isStreaming: viewModel.isStreaming,
            embedded: embedded,
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
    let isLast: Bool
    let prevMessage: ChatMessage?
    let isStreaming: Bool
    /// Teil eines Antwort-Blocks: Bubble zeigt nur Ergebnisse (siehe AssistantTurnRow).
    var embedded: Bool = false
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
                    embedded: embedded,
                    fontScale: fontScale,
                    canRegenerate: message.role == "assistant" && isLast && !isStreaming,
                    onRegenerate: {
                        userScrolledUp = false
                        viewModel.regenerateLastAnswer()
                    },
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

// MARK: - WelcomeCardButton (Farbig akzentuierte Schnellstart-Karte)

private struct WelcomeCardButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(isHovered ? 0.20 : 0.13))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tint)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(subtitle)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
            .padding(DS.Space.m)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                    .fill(isHovered ? tint.opacity(0.05) : DS.Surface.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                    .stroke(isHovered ? tint.opacity(0.28) : DS.Ink.hairline, lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(isHovered ? 0.05 : 0.025), radius: isHovered ? 8 : 5, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(L("Setzt eine Vorlage ins Eingabefeld"))
        .accessibilityLabel("\(title): \(subtitle)")
    }
}



// MARK: - Antwort-Blöcke

/// Zeile der Nachrichtenliste: einzelne Nachricht (Nutzer, System, Dokument) oder eine komplette
/// Antwort des Modells aus mehreren aufeinanderfolgenden Assistenten-Nachrichten.
enum ChatRowItem: Identifiable {
    case single(ChatMessage)
    case turn([ChatMessage])

    var id: UUID {
        switch self {
        case .single(let message): return message.id
        case .turn(let messages): return messages[0].id
        }
    }

    static func items(from messages: [ChatMessage]) -> [ChatRowItem] {
        var items: [ChatRowItem] = []
        var turn: [ChatMessage] = []
        for message in messages {
            if message.role == "assistant" {
                turn.append(message)
            } else {
                if !turn.isEmpty { items.append(.turn(turn)); turn = [] }
                items.append(.single(message))
            }
        }
        if !turn.isEmpty { items.append(.turn(turn)) }
        return items
    }
}

/// Eine Antwort: Avatar, darüber die Arbeitsschritte, darunter die Ergebnisse (Plot, Simulation,
/// Quizkarte, Antworttext) – ohne die frühere Überlappung per negativem Abstand.
private struct AssistantTurnRow<Row: View>: View {
    let messages: [ChatMessage]
    let isRunning: Bool
    let row: (ChatMessage, Bool) -> Row

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            LernAssistBrandIcon(size: 30)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: DS.Space.s) {
                WorkStepsView(messages: messages, isRunning: isRunning)
                    .equatable()
                ForEach(messages) { message in
                    row(message, message.id == messages.last?.id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}


// MARK: - Hinweis nach „Als Karte merken“

private struct FlashcardNoticeView: View {
    let notice: FlashcardNotice
    let onShow: () -> Void
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(notice.isError ? Color.orange : DS.Accent.emerald)
            Text(notice.text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
            if !notice.isError {
                Divider().frame(height: 12)
                Button(L("Ansehen"), action: onShow).buttonStyle(.plain).foregroundStyle(DS.Ink.accent)
                Button(L("Rückgängig"), action: onUndo).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, 7)
        .background(Capsule().fill(DS.Surface.pill).shadow(color: .black.opacity(0.12), radius: 10, y: 3))
        .overlay(Capsule().stroke(DS.Ink.hairline, lineWidth: 0.75))
        .task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            onDismiss()
        }
    }
}

// MARK: - Hinweis des Verbindungswächters

private struct ConnectionIssueBanner: View {
    let issue: ConnectionIssue
    let moreCount: Int
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(Color.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(issue.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if moreCount > 0 {
                    Text(L("und \(moreCount) weitere Verbindung(en)"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: DS.Space.s)
            Button(L("Einstellungen"), action: onOpenSettings)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(DS.Ink.accent)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("Ausblenden – erscheint erst wieder, wenn die Verbindung einmal funktioniert hat und erneut ausfällt"))
            .accessibilityLabel(L("Hinweis ausblenden"))
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, 9)
        .frame(maxWidth: 560)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Surface.pill)
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DS.Ink.hairline, lineWidth: 0.75))
    }
}

// MARK: - Sidebar Resize & Drag Support

private struct FlowCursorModifier: ViewModifier {
    let cursor: NSCursor
    @State private var isPushed = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovered in
                if isHovered && !isPushed {
                    cursor.push()
                    isPushed = true
                } else if !isHovered && isPushed {
                    NSCursor.pop()
                    isPushed = false
                }
            }
            .onDisappear {
                if isPushed {
                    NSCursor.pop()
                    isPushed = false
                }
            }
    }
}

private extension View {
    func flowCursor(_ cursor: NSCursor) -> some View {
        modifier(FlowCursorModifier(cursor: cursor))
    }
}

/// Seitenleiste mit gespeicherter Breite.
private struct SidebarColumn: View {
    @ObservedObject var viewModel: ChatViewModel
    @AppStorage("sidebarWidth") private var width: Double = 240

    var body: some View {
        SidebarView(viewModel: viewModel)
            .frame(width: CGFloat(max(195, min(width, 460))))
    }
}

private struct SidebarResizeHandle: View {
    @AppStorage("sidebarWidth") private var width: Double = 240
    @Binding var isVisible: Bool
    var minWidth: Double = 195
    var maxWidth: Double = 460
    var collapseThreshold: Double = 140
    var defaultWidth: Double = 240

    @State private var isHovered = false
    @State private var isDragging = false
    @State private var dragStartWidth: Double? = nil

    private static let lineInset: CGFloat = 20

    var body: some View {
        ZStack {
            Color.clear
                .frame(width: 8)

            Rectangle()
                .fill(isHovered || isDragging ? DS.Ink.accent.opacity(0.40) : DS.Ink.hairline)
                .frame(width: isHovered || isDragging ? 2 : 1)
                // Oben und unten gleicher Abstand – die Linie endet wie die Karte vor dem Fensterrand.
                .padding(.vertical, Self.lineInset)
                .animation(.easeInOut(duration: 0.15), value: isHovered || isDragging)
        }
        .frame(width: 8)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .flowCursor(.resizeLeftRight)
        .onHover { isHovered = $0 }
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    if dragStartWidth == nil {
                        dragStartWidth = width
                        isDragging = true
                    }
                    guard let start = dragStartWidth else { return }
                    let proposed = start + Double(value.translation.width)
                    if proposed < collapseThreshold {
                        withAnimation(.snappy(duration: 0.25)) {
                            isVisible = false
                        }
                    } else {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            width = max(minWidth, min(maxWidth, proposed))
                        }
                    }
                }
                .onEnded { _ in
                    dragStartWidth = nil
                    isDragging = false
                }
        )
        .onTapGesture(count: 2) {
            withAnimation(.snappy(duration: 0.2)) {
                width = defaultWidth
            }
        }
        .help(L("Seitenleiste anpassen (Ziehen zum Vergrößern/Verkleinern, Doppelklick zum Zurücksetzen)"))
    }
}

private struct SidebarEdgePullZone: View {
    @AppStorage("sidebarWidth") private var width: Double = 240
    @Binding var isVisible: Bool
    var minWidth: Double = 195
    var maxWidth: Double = 460
    var defaultWidth: Double = 240

    @State private var isHovered = false
    @State private var isDragging = false

    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear
                .frame(width: 12)

            if isHovered || isDragging {
                Capsule()
                    .fill(DS.Ink.accent.opacity(0.45))
                    .frame(width: 3, height: 48)
                    .padding(.leading, 2)
                    .transition(.opacity)
            }
        }
        .frame(width: 12)
        .frame(maxHeight: .infinity)
        .padding(.top, 42) // Lässt die Fensterknöpfe (Traffic Lights) unberührt
        .contentShape(Rectangle())
        .flowCursor(.resizeRight)
        .onHover { isHovered = $0 }
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        withAnimation(.snappy(duration: 0.2)) {
                            isVisible = true
                        }
                    }
                    let proposed = minWidth + Double(value.translation.width)
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        width = max(minWidth, min(maxWidth, proposed))
                    }
                }
                .onEnded { _ in
                    isDragging = false
                }
        )
        .onTapGesture {
            withAnimation(.snappy(duration: 0.25)) {
                isVisible = true
            }
        }
        .help(L("Seitenleiste herausziehen (Ziehen oder Klicken)"))
    }
}
