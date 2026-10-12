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
        VStack(spacing: 8) {
            // Screenshot-Vorschau – Klick öffnet das Markup-Tool (Kreise/Pfeile/Rechtecke
            // einzeichnen), OHNE den schnellen "Screenshot → Chat"-Weg zu verändern: Der
            // Screenshot landet weiterhin sofort unkommentiert hier und kann direkt gesendet
            // werden; Markup ist ein rein optionaler Zwischenschritt auf Wunsch.
            if let image = lastCapturedImage {
                HStack(alignment: .top, spacing: DS.Space.s) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                                .stroke(DS.Ink.hairline, lineWidth: 0.5)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { isShowingMarkup = true }
                        .accessibilityLabel("Screenshot-Vorschau")
                        .accessibilityAddTraits(.isButton)
                        .help("Klicken zum Markieren (Kreise, Pfeile, Rechtecke)")
                    GlassEffectContainer(spacing: DS.Space.xs) {
                        VStack(spacing: DS.Space.xs) {
                            Button { isShowingMarkup = true } label: {
                                Image(systemName: "pencil.tip.crop.circle")
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .help("Markieren oder Ausschnitt wählen")
                            .accessibilityLabel("Screenshot markieren")
                            Button { lastCapturedImage = nil } label: {
                                Image(systemName: "xmark")
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .help("Screenshot entfernen")
                            .accessibilityLabel("Screenshot entfernen")
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            
            // Warteschlange: Folgefragen/Screenshots, die während der laufenden Generierung
            // abgeschickt wurden und automatisch nachgereicht werden, sobald diese fertig ist.
            if !viewModel.queuedMessages.isEmpty {
                HStack {
                    Button(action: { showQueuedMessages.toggle() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "text.badge.plus")
                            Text("\(viewModel.queuedMessages.count) in Warteschlange")
                                .font(.caption)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(DS.Ink.accent.opacity(0.12))
                        .cornerRadius(6)
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
                .padding(.horizontal)
            }

            // Document Processing Status
            if docProcessor.currentStatus.isProcessing {
                HStack {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                    Text(docProcessor.currentStatus.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if docProcessor.currentStatus.estimatedTokens > 0 {
                        Text("~ \(docProcessor.currentStatus.estimatedTokens) Tokens")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
            }

            HStack(spacing: 10) {
                // Screenshot-Button (GUI-Neubau: Glas-Kreis statt flacher Button)
                Button(action: capture) {
                    Image(systemName: "camera.viewfinder")
                        .symbolEffect(.bounce, value: lastCapturedImage != nil)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: Circle())
                .help("Screenshot aufnehmen (Interaktiv)")
                .accessibilityLabel("Screenshot aufnehmen")
                .disabled(docProcessor.currentStatus.isProcessing)
                
                // Datei-Button (Büroklammer, Glas-Kreis)
                Button(action: { showFilePicker = true }) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: Circle())
                .help("Datei hochladen (PDF, TXT, MD)")
                .accessibilityLabel("Datei anhängen")
                .disabled(viewModel.isStreaming || docProcessor.currentStatus.isProcessing)
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

                // Ein NSTextView bricht lange Zeilen zuverlässig um. TextField(axis: .vertical)
                // blieb in diesem NSPanel trotz ScrollView einzeilig und scrollte den Text
                // horizontal. Der Editor misst seine umbrochene Texthöhe, wächst bis maxInputHeight
                // und bekommt danach einen nativen vertikalen Scrollbalken.
                ZStack(alignment: .topLeading) {
                    GrowingTextEditor(
                        text: $inputText,
                        height: $inputFieldHeight,
                        minHeight: minInputHeight,
                        maxHeight: maxInputHeight,
                        onSubmit: handleInputSubmit
                    )
                    if inputText.isEmpty {
                        Text("Frage stellen oder Screenshot senden...")
                            .font(.system(size: NSFont.systemFontSize))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 3)
                            .padding(.top, 4)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: min(max(inputFieldHeight, minInputHeight), maxInputHeight))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Space.m)
                    .padding(.vertical, DS.Space.s)
                    // Composer als Liquid-Glass-Fläche (Phase G): Der Composer ist Steuerfläche,
                    // nicht Content – genau dort gehört Glass hin.
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: DS.Radius.extraLarge, style: .continuous))
                    .onChange(of: inputText) { newValue in
                        if newValue.hasPrefix("/") {
                            matchedCommands = viewModel.slashCommandRegistry.matching(prefix: newValue)
                            showSlashCommands = !matchedCommands.isEmpty
                            selectedCommandIndex = 0
                        } else {
                            showSlashCommands = false
                        }
                    }
                    .popover(isPresented: $showSlashCommands, attachmentAnchor: .point(.top), arrowEdge: .top) {
                        SlashCommandList(
                            commands: matchedCommands,
                            selectedIndex: $selectedCommandIndex,
                            onSelect: { cmd in
                                inputText = "/" + cmd.id + " "
                                showSlashCommands = false
                            }
                        )
                    }
                    .disabled(docProcessor.currentStatus.isProcessing)

                // Senden / Stopp / Zur Warteschlange hinzufügen
                if viewModel.isStreaming {
                    Button(action: cancel) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(.red).interactive(), in: Circle())
                    .help("Generierung abbrechen")
                    .accessibilityLabel("Generierung abbrechen")
                }

                if viewModel.isStreaming {
                    // Während der Stream läuft, killt ein direktes sendMessage() den laufenden
                    // Request und den KV-Cache-Vorteil der Konversation – deshalb landet die
                    // Eingabe hier in der Warteschlange und wird erst nachgereicht, sobald die
                    // aktuelle Antwort fertig ist (siehe ChatViewModel.isStreaming didSet).
                    Button(action: handleSend) {
                        Image(systemName: "text.badge.plus")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(canSend ? Color.primary : Color.secondary.opacity(0.4))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular, in: Circle())
                    .disabled(!canSend)
                    .help("Zur Warteschlange hinzufügen – wird nach der aktuellen Antwort automatisch gesendet")
                } else {
                    Button(action: handleSend) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(.blue).interactive(), in: Circle())
                    .opacity(canSend ? 1 : 0.4)
                    .disabled(!canSend)
                    .help("Senden (Return)")
                    .accessibilityLabel("Senden")
                }
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.top, DS.Space.xs)
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
            let command = matchedCommands[selectedCommandIndex]
            inputText = "/" + command.id + " "
            showSlashCommands = false
            return
        }
        handleSend()
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
        textView.textContainerInset = NSSize(width: 2, height: 4)
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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(commands.enumerated()), id: \.element.id) { index, cmd in
                Button(action: { onSelect(cmd) }) {
                    HStack {
                        Text("/\(cmd.id)").font(.system(.body, design: .monospaced)).bold()
                        if let hint = cmd.paramHint {
                            Text(hint).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(cmd.description).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(index == selectedIndex ? DS.Ink.accent.opacity(0.2) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 300)
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
