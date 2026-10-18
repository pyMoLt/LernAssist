import SwiftUI
import AppKit
import UniformTypeIdentifiers
import os

// MARK: - InputArea

struct InputArea: View {
    @ObservedObject var viewModel: ChatViewModel
    @Binding var inputText: String
    @Binding var lastCapturedImage: NSImage?
    let send: () -> Void
    let enqueue: () -> Void
    let capture: () -> Void
    let cancel: () -> Void
    let addSystemMessage: (String) -> Void

    @State private var showSlashCommands = false
    @State private var matchedCommands: [SlashCommand] = []
    @State private var selectedCommandIndex = 0
    @State private var isHoveringDropZone = false
    @State private var showQueuedMessages = false
    @ObservedObject private var docProcessor = DocumentProcessor.shared
    @State private var showFilePicker = false
    @State private var isShowingMarkup = false
    /// Gemessene natürliche Höhe des Eingabefelds (siehe InputHeightPreferenceKey) – treibt die
    /// Höhe der umgebenden ScrollView, damit sie bei leerem/kurzem Text klein bleibt und erst ab
    /// maxInputHeight tatsächlich scrollt, statt immer die volle Maximalhöhe einzunehmen.
    @State private var inputFieldHeight: CGFloat = 24
    private let minInputHeight: CGFloat = 24
    private let maxInputHeight: CGFloat = 160

    var body: some View {
        VStack(spacing: 6) {
            // Warteschlange: Folgefragen/Screenshots während laufender Generierung
            if !viewModel.queuedMessages.isEmpty {
                HStack {
                    Button(action: { showQueuedMessages.toggle() }) {
                        HStack(spacing: 5) {
                            Image(systemName: "text.badge.plus")
                                .font(.system(size: 11, weight: .semibold))
                            Text("\(viewModel.queuedMessages.count) in Warteschlange")
                                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        }
                        .foregroundStyle(DS.Accent.brand)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(DS.Accent.brand.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help("Wartende Nachrichten anzeigen")
                    .popover(isPresented: $showQueuedMessages, arrowEdge: .top) {
                        QueuedMessagesList(
                            messages: viewModel.queuedMessages,
                            onRemove: { id in viewModel.removeQueuedMessage(id: id) }
                        )
                    }
                    Spacer()
                }
                .padding(.horizontal, DS.Space.xl)
            }

            // Document Processing Status
            if docProcessor.currentStatus.isProcessing {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 16, height: 16)
                    Text(docProcessor.currentStatus.statusText)
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if docProcessor.currentStatus.estimatedTokens > 0 {
                        Text("~ \(docProcessor.currentStatus.estimatedTokens) Tokens")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, DS.Space.xl)
            }

            // Slash-Befehle: eingebettete Vorschlagsliste direkt über der Eingabe (statt Popover,
            // das auf macOS bei sofort gesetztem Text mit Höhe 0 erschien).
            if showSlashCommands && !matchedCommands.isEmpty {
                SlashCommandList(
                    commands: matchedCommands,
                    selectedIndex: $selectedCommandIndex,
                    onSelect: { cmd in insertCommand(cmd) }
                )
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                        .fill(DS.Surface.pill)
                        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                        .stroke(DS.Ink.hairline, lineWidth: 0.75)
                )
                .padding(.horizontal, DS.Space.xl)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // ── Einheitliche, schwebende Composer-Insel ──────────────────────
            VStack(alignment: .leading, spacing: DS.Space.s) {
                // Integrierte Screenshot-Vorschau oben in der Composer-Insel
                if let image = lastCapturedImage {
                    HStack(alignment: .top, spacing: DS.Space.s) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 68)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                                    .stroke(DS.Ink.hairline, lineWidth: 0.75)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { isShowingMarkup = true }
                            .accessibilityLabel("Screenshot-Vorschau")
                            .accessibilityAddTraits(.isButton)
                            .help("Klicken zum Markieren (Kreise, Pfeile, Rechtecke)")

                        VStack(spacing: 5) {
                            Button { isShowingMarkup = true } label: {
                                Image(systemName: "pencil.tip.crop.circle")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(DS.Accent.brand)
                                    .frame(width: 26, height: 26)
                                    .background(Circle().fill(DS.Accent.brand.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                            .help("Markieren oder Ausschnitt wählen")
                            .accessibilityLabel("Screenshot markieren")

                            Button { lastCapturedImage = nil } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 26, height: 26)
                                    .background(Circle().fill(DS.Surface.control))
                            }
                            .buttonStyle(.plain)
                            .help("Screenshot entfernen")
                            .accessibilityLabel("Screenshot entfernen")
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                }

                // Haupt-Eingabezeile: Kamera + Anhang links integriert, Textfeld mittig, Senden/Stopp rechts integriert
                HStack(alignment: .bottom, spacing: 6) {
                    HStack(spacing: 2) {
                        ComposerIconButton(
                            systemImage: "camera.viewfinder",
                            help: "Screenshot aufnehmen (Interaktiv)",
                            accessibilityLabel: "Screenshot aufnehmen",
                            tint: DS.Accent.brand,
                            disabled: docProcessor.currentStatus.isProcessing,
                            action: capture
                        )

                        ComposerIconButton(
                            systemImage: "paperclip",
                            help: "Datei hochladen (PDF, TXT, MD)",
                            accessibilityLabel: "Datei anhängen",
                            tint: DS.Accent.blue,
                            disabled: viewModel.isStreaming || docProcessor.currentStatus.isProcessing,
                            action: { showFilePicker = true }
                        )
                        .fileImporter(
                            isPresented: $showFilePicker,
                            allowedContentTypes: Self.allowedDocumentTypes,
                            allowsMultipleSelection: true
                        ) { result in
                            switch result {
                            case .success(let urls):
                                processFiles(urls)
                            case .failure(let error):
                                AppLog.ui.error("Fehler beim Dateiauswählen: \(error.localizedDescription)")
                            }
                        }
                    }
                    .padding(.bottom, 1)

                    ZStack(alignment: .topLeading) {
                        GrowingTextEditor(
                            text: $inputText,
                            height: $inputFieldHeight,
                            minHeight: minInputHeight,
                            maxHeight: maxInputHeight,
                            onSubmit: handleInputSubmit,
                            onCommand: handleEditorCommand
                        )
                        // Graue Parameter-Platzhalter hinter dem eingefügten Befehl („/quiz ▏[Anzahl] …“).
                        // Gleiche Schrift und Einrückung wie das Textfeld, damit der Hinweis direkt
                        // hinter der Einfügemarke steht; verschwindet Stück für Stück beim Tippen.
                        if let hint = parameterGhost {
                            (Text(inputText).foregroundColor(.clear) + Text(hint).foregroundColor(Color(nsColor: .tertiaryLabelColor)))
                                .font(Font(NSFont.systemFont(ofSize: NSFont.systemFontSize)))
                                .lineLimit(1)
                                .padding(.leading, GrowingTextEditor.textInset.width + GrowingTextEditor.linePadding)
                                .padding(.top, GrowingTextEditor.textInset.height)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        if inputText.isEmpty {
                            Text("Frage stellen oder Screenshot senden…")
                                .font(.system(size: 13.5, design: .rounded))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 4)
                                .padding(.top, 3)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(height: min(max(inputFieldHeight, minInputHeight), maxInputHeight))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
                    .onChange(of: inputText) { _, newValue in
                        // Vorschläge nur, solange der Befehlsname getippt wird (bis zum ersten Leerzeichen).
                        if newValue.hasPrefix("/"), !newValue.contains(" ") {
                            let matches = viewModel.slashCommandRegistry.matching(prefix: newValue)
                            withAnimation(.snappy(duration: 0.18)) {
                                matchedCommands = matches
                                showSlashCommands = !matchedCommands.isEmpty
                            }
                            selectedCommandIndex = 0
                        } else if showSlashCommands {
                            withAnimation(.snappy(duration: 0.18)) { showSlashCommands = false }
                        }
                    }
                    .disabled(docProcessor.currentStatus.isProcessing)

                    // Rechts in der Kapsel: Stopp / Queue / Senden
                    HStack(spacing: 6) {
                        if viewModel.isStreaming {
                            Button(action: cancel) {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 30, height: 30)
                                    .background(Circle().fill(DS.Accent.rose))
                            }
                            .buttonStyle(.plain)
                            .help("Generierung abbrechen")
                            .accessibilityLabel("Generierung abbrechen")

                            if canSend {
                                Button(action: handleSend) {
                                    Image(systemName: "text.badge.plus")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(DS.Accent.brand)
                                        .frame(width: 30, height: 30)
                                        .background(Circle().fill(DS.Accent.brand.opacity(0.14)))
                                }
                                .buttonStyle(.plain)
                                .help("Zur Warteschlange hinzufügen – wird nach der aktuellen Antwort automatisch gesendet")
                            }
                        } else {
                            Button(action: handleSend) {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 13.5, weight: .bold))
                                    .foregroundStyle(canSend ? Color.white : Color.secondary.opacity(0.5))
                                    .frame(width: 30, height: 30)
                                    .background(
                                        Circle()
                                            .fill(
                                                canSend
                                                    ? AnyShapeStyle(DS.Accent.brandGradient)
                                                    : AnyShapeStyle(Color.primary.opacity(0.07))
                                            )
                                    )
                                    .shadow(color: canSend ? DS.Accent.brand.opacity(0.28) : .clear, radius: 5, x: 0, y: 2)
                            }
                            .buttonStyle(.plain)
                            .disabled(!canSend)
                            .help("Senden (Return)")
                            .accessibilityLabel("Senden")
                        }
                    }
                    .padding(.bottom, 1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(DS.Surface.pill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(
                        (!inputText.isEmpty || lastCapturedImage != nil)
                            ? DS.Accent.brand.opacity(0.28)
                            : DS.Ink.hairline,
                        lineWidth: 0.85
                    )
            )
            .shadow(color: .black.opacity(0.05), radius: 12, x: 0, y: 3)
            .frame(maxWidth: 1100)
            .padding(.horizontal, DS.Space.xl)
            .padding(.top, 2)
            .padding(.bottom, DS.Space.m)
        }
        // Kein opaker Balken mehr: Der Composer schwebt als Glas auf dem Chat-Hintergrund.
        .overlay(
            Group {
                if isHoveringDropZone {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(DS.Ink.accent, style: StrokeStyle(lineWidth: 3, dash: [10]))
                        .background(DS.Ink.accent.opacity(0.1))
                        .allowsHitTesting(false)
                }
            }
        )
        .onDrop(of: [.fileURL], isTargeted: $isHoveringDropZone) { providers in
            var droppedUrls: [URL] = []
            let group = DispatchGroup()
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let fileURL = url {
                        droppedUrls.append(fileURL)
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                if !droppedUrls.isEmpty {
                    processFiles(droppedUrls)
                }
            }
            return true
        }
        .sheet(isPresented: $isShowingMarkup) {
            if let image = lastCapturedImage {
                ScreenshotMarkupView(
                    originalImage: image,
                    onDone: { annotated, isCrop in
                        lastCapturedImage = annotated
                        if isCrop && inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            inputText = "Erkläre diesen Ausschnitt."
                        }
                        isShowingMarkup = false
                    },
                    onCancel: { isShowingMarkup = false }
                )
                .frame(minWidth: 480, idealWidth: 680, minHeight: 380, idealHeight: 520)
            }
        }
    }

    private func processFiles(_ urls: [URL]) {
        for url in urls {
            viewModel.addDocument(url: url)
        }
    }

    private func handleInputSubmit() {
        if showSlashCommands && !matchedCommands.isEmpty {
            insertCommand(matchedCommands[min(selectedCommandIndex, matchedCommands.count - 1)])
            return
        }
        handleSend()
    }

    /// Übernimmt einen Befehl aus der Liste ins Eingabefeld, ohne ihn auszuführen. Die möglichen
    /// Parameter erscheinen danach als grauer Platzhalter (siehe `parameterGhost`).
    private func insertCommand(_ command: SlashCommand) {
        inputText = "/" + command.id + " "
        withAnimation(.snappy(duration: 0.18)) { showSlashCommands = false }
    }

    /// Pfeiltasten, Tab und Escape steuern die Befehlsliste, solange sie offen ist.
    private func handleEditorCommand(_ selector: Selector) -> Bool {
        guard showSlashCommands, !matchedCommands.isEmpty else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            selectedCommandIndex = (selectedCommandIndex + 1) % matchedCommands.count
        case #selector(NSResponder.moveUp(_:)):
            selectedCommandIndex = (selectedCommandIndex - 1 + matchedCommands.count) % matchedCommands.count
        case #selector(NSResponder.insertTab(_:)):
            insertCommand(matchedCommands[min(selectedCommandIndex, matchedCommands.count - 1)])
        case #selector(NSResponder.cancelOperation(_:)):
            withAnimation(.snappy(duration: 0.18)) { showSlashCommands = false }
        default:
            return false
        }
        return true
    }

    /// Noch nicht ausgefüllte Parameter des getippten Befehls, z. B. „[Stufe] [Thema]“ nach „/quiz 10 “.
    private var parameterGhost: String? {
        guard inputText.hasPrefix("/"), inputText.hasSuffix(" "), !inputText.contains("\n") else { return nil }
        let parts = inputText.dropFirst().split(separator: " ")
        guard let name = parts.first?.lowercased(),
              let command = viewModel.slashCommandRegistry.commands.first(where: { $0.id == name || $0.aliases.contains(name) }),
              let hint = command.paramHint else { return nil }
        return Self.remainingParameters(hint: hint, typedArguments: parts.count - 1)
    }

    /// Zerlegt „[Anzahl] [Stufe] <Thema>“ in Platzhalter und lässt die bereits getippten weg.
    static func remainingParameters(hint: String, typedArguments: Int) -> String? {
        var tokens: [String] = []
        var current = ""
        var depth = 0
        for char in hint {
            if char == "[" || char == "<" { depth += 1 }
            if char == " " && depth == 0 {
                if !current.isEmpty { tokens.append(current) }
                current = ""
                continue
            }
            current.append(char)
            if char == "]" || char == ">" { depth = max(0, depth - 1) }
        }
        if !current.isEmpty { tokens.append(current) }
        guard typedArguments < tokens.count else { return nil }
        return tokens[typedArguments...].joined(separator: " ")
    }

    /// Muss mit den von `DocumentProcessor` tatsächlich unterstützten Formaten übereinstimmen.
    /// War vorher auf [.pdf, .plainText, .json, .commaSeparatedText] beschränkt – Word/RTF/
    /// PowerPoint-Dateien wurden von DocumentProcessor längst korrekt verarbeitet (und funktionierten
    /// bereits per Drag&Drop, das keinen Typ-Filter hat), waren über den Büroklammer-Button im
    /// Dateiauswahl-Dialog aber gar nicht erst anwählbar.
    private static let allowedDocumentTypes: [UTType] = {
        let extra = ["doc", "docx", "ppt", "pptx", "md"].compactMap { UTType(filenameExtension: $0) }
        return [.pdf, .plainText, .json, .commaSeparatedText, .rtf] + extra
    }()

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || lastCapturedImage != nil
    }

    /// Befehle, die auch während einer laufenden Generierung gefahrlos ausgeführt werden können:
    /// sie mutieren weder die aktive Session noch den laufenden Stream.
    private static let streamingSafeCommandIDs: Set<String> = ["settings", "model", "endpoint", "help"]

    private func handleSend() {
        let inputTrimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Slash-Befehle brauchen unmittelbaren Zugriff auf den ViewModel-State (z.B. /clear startet
        // sofort einen neuen Chat). Während einer Antwort läuft, kollidieren session-mutierende
        // Befehle (/compact, /clear, /verify, /export) mit dem laufenden Stream – sie werden
        // abgelehnt statt (wie vorher, Audit M7) als normale Chat-Nachricht in die Warteschlange
        // und damit ans Modell geschickt zu werden. Zustands-Befehle (/model, /endpoint, /settings,
        // /help) wirken sofort, sie betreffen ohnehin nur die nächste Anfrage.
        if inputTrimmed.hasPrefix("/") {
            let parts = inputTrimmed.split(separator: " ", maxSplits: 1)
            // Lowercased, damit z.B. "/Model" genauso greift wie "/model" – die Autovervollständigung
            // (SlashCommandRegistry.matching) ist bereits case-insensitive, dieser exakte
            // Enter-Abgleich war es vorher nicht und schickte Großschreibungs-Varianten unerkannt
            // als normale Chat-Nachricht ans Modell statt den Befehl auszuführen.
            let cmdName = String(parts[0].dropFirst()).lowercased()
            let args = parts.count > 1 ? String(parts[1]) : ""

            if let cmd = viewModel.slashCommandRegistry.commands.first(where: { $0.id == cmdName || $0.aliases.contains(cmdName) }) {
                if viewModel.isStreaming && !Self.streamingSafeCommandIDs.contains(cmd.id) {
                    addSystemMessage("Befehl `/\(cmd.id)` während der laufenden Antwort ignoriert – bitte nach Abschluss erneut senden.")
                } else {
                    // Kein generisches "Befehl ausgeführt" mehr (Audit M13): Es landete bei /clear im
                    // alten Chat und war reines Rauschen – jeder Befehl gibt selbst eine passende
                    // Rückmeldung (oder sein Effekt ist die Rückmeldung, wie der neue leere Chat).
                    cmd.action(args)
                }
                inputText = ""
                return
            }
        }
        if viewModel.isStreaming {
            enqueue()
            return
        }
        send()
    }
}

// MARK: - GrowingTextEditor

/// NSTextView liefert tatsächlichen Zeilenumbruch und vertikales Scrollen im Chat-Composer.
/// Return sendet wie zuvor; Shift+Return fügt einen Zeilenumbruch ein.
private struct GrowingTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let onSubmit: () -> Void
    /// Tastenbefehle (Pfeile, Tab, Escape) zuerst an die Eingabe – true = verarbeitet.
    var onCommand: (Selector) -> Bool = { _ in false }

    /// Innenabstand und Zeilen-Padding des Textfelds (für exakt ausgerichtete Platzhalter).
    static let textInset = NSSize(width: 2, height: 4)
    static let linePadding: CGFloat = 5

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = NSTextView(frame: .zero)
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.textContainerInset = Self.textInset
        textView.textContainer?.lineFragmentPadding = Self.linePadding
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Nur echte Änderungen von außen übernehmen (Leeren nach dem Senden, Slash-Vervollständigung,
        // Prefill). Beim schnellen Tippen kam hier sonst ein veralteter SwiftUI-Wert an, der den
        // Text zurücksetzte und die Einfügemarke an den Anfang springen ließ („ie/search … Leitlin“).
        // Leeren (nach dem Senden) ist immer eine echte Änderung von außen.
        if textView.string != text, text.isEmpty || !context.coordinator.recentTextsFromView.contains(text) {
            textView.string = text
            context.coordinator.recentTextsFromView = [text]
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        DispatchQueue.main.async {
            context.coordinator.updateLayout(in: scrollView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextEditor
        /// Zuletzt vom Textfeld selbst gemeldete Stände: Verspätete SwiftUI-Updates mit einem
        /// dieser Werte sind Echos und dürfen das Feld nicht zurücksetzen.
        var recentTextsFromView: [String] = []

        init(parent: GrowingTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  let scrollView = textView.enclosingScrollView else { return }
            recentTextsFromView.append(textView.string)
            if recentTextsFromView.count > 64 { recentTextsFromView.removeFirst(recentTextsFromView.count - 64) }
            parent.text = textView.string
            updateLayout(in: scrollView)
            let end = (textView.string as NSString).length
            textView.scrollRangeToVisible(NSRange(location: end, length: 0))
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if parent.onCommand(commandSelector) { return true }
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                return false
            }
            parent.onSubmit()
            return true
        }

        func updateLayout(in scrollView: NSScrollView) {
            guard let textView = scrollView.documentView as? NSTextView else { return }
            let width = max(1, scrollView.contentSize.width)
            let desiredHeight = Self.measuredHeight(for: textView.string, width: width, font: textView.font ?? .systemFont(ofSize: NSFont.systemFontSize))
            let documentHeight = max(desiredHeight, scrollView.contentSize.height)
            textView.setFrameSize(NSSize(width: width, height: documentHeight))
            let clampedHeight = min(max(desiredHeight, parent.minHeight), parent.maxHeight)
            if abs(parent.height - clampedHeight) > 0.5 {
                parent.height = clampedHeight
            }
        }

        private static func measuredHeight(for text: String, width: CGFloat, font: NSFont) -> CGFloat {
            let container = NSTextContainer(size: NSSize(width: max(1, width - 8), height: CGFloat.greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            let layoutManager = NSLayoutManager()
            layoutManager.addTextContainer(container)
            let storage = NSTextStorage(string: text.isEmpty ? " " : text, attributes: [.font: font])
            storage.addLayoutManager(layoutManager)
            layoutManager.ensureLayout(for: container)
            return ceil(layoutManager.usedRect(for: container).height) + 8
        }
    }
}

// MARK: - SlashCommandList

struct SlashCommandList: View {
    let commands: [SlashCommand]
    @Binding var selectedIndex: Int
    let onSelect: (SlashCommand) -> Void

    /// Etwa acht Zeilen sichtbar, der Rest scrollt – alle Befehle ohne /help im Blick.
    private let maxListHeight: CGFloat = 260

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, cmd in
                        Button(action: { onSelect(cmd) }) {
                            HStack(spacing: DS.Space.s) {
                                Text("/\(cmd.id)")
                                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(index == selectedIndex ? DS.Ink.accent : .primary)
                                if let hint = cmd.paramHint {
                                    Text(hint)
                                        .font(.system(size: 11, design: .rounded))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                Spacer(minLength: DS.Space.m)
                                Text(cmd.description)
                                    .font(.system(size: 11.5, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .layoutPriority(1)
                            }
                            .padding(.horizontal, DS.Space.m)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                                    .fill(index == selectedIndex ? DS.Surface.selection : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(index)
                        .accessibilityLabel("/\(cmd.id): \(cmd.description)")
                    }
                }
                .padding(DS.Space.xs)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: maxListHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selectedIndex) { _, index in
                withAnimation(.snappy(duration: 0.12)) { proxy.scrollTo(index) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - QueuedMessagesList

struct QueuedMessagesList: View {
    let messages: [QueuedMessage]
    let onRemove: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Warteschlange")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)

            ForEach(messages) { msg in
                HStack(alignment: .top, spacing: 8) {
                    if msg.imageBase64 != nil {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
                    Text(msg.text.isEmpty ? "[Screenshot]" : msg.text)
                        .font(.callout)
                        .lineLimit(3)
                    Spacer()
                    Button(action: { onRemove(msg.id) }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
            }
        }
        .padding(.bottom, 4)
        .frame(minWidth: 280, maxWidth: 360)
    }
}

// MARK: - ComposerIconButton (Integrierter Button links in der Composer-Kapsel)

private struct ComposerIconButton: View {
    let systemImage: String
    let help: String
    let accessibilityLabel: String
    var tint: Color = DS.Accent.brand
    var disabled: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isHovered && !disabled ? tint : .secondary)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(isHovered && !disabled ? tint.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .onHover { isHovered = $0 }
    }
}

