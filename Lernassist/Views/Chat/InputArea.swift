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
    @State private var inputFieldHeight: CGFloat = 20
    private let minInputHeight: CGFloat = 20
    private let maxInputHeight: CGFloat = 160

    var body: some View {
        VStack(spacing: 8) {
            // Screenshot-Vorschau – Klick öffnet das Markup-Tool (Kreise/Pfeile/Rechtecke
            // einzeichnen), OHNE den schnellen "Screenshot → Chat"-Weg zu verändern: Der
            // Screenshot landet weiterhin sofort unkommentiert hier und kann direkt gesendet
            // werden; Markup ist ein rein optionaler Zwischenschritt auf Wunsch.
            if let image = lastCapturedImage {
                HStack(alignment: .top) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 72)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                        )
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "pencil.circle.fill")
                                .font(.system(size: 15))
                                .foregroundColor(.blue)
                                .background(Circle().fill(.white))
                                .padding(3)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { isShowingMarkup = true }
                        .help("Klicken zum Markieren (Kreise, Pfeile, Rechtecke)")
                    Button(action: { lastCapturedImage = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
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
                        .background(Color.blue.opacity(0.12))
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
                        .foregroundColor(.secondary)
                    Spacer()
                    if docProcessor.currentStatus.estimatedTokens > 0 {
                        Text("~ \(docProcessor.currentStatus.estimatedTokens) Tokens")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)
            }

            HStack(spacing: 10) {
                // Screenshot-Button (GUI-Neubau: Glas-Kreis statt flacher Button)
                Button(action: capture) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: Circle())
                .help("Screenshot aufnehmen (Interaktiv)")
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

                // Texteingabe
                // Bei langen Nachrichten wuchs das Feld vorher NICHT über sein eigenes
                // lineLimit(1...8) hinaus scrollbar per Mausrad/Trackpad – TextField(axis: .vertical)
                // bietet auf macOS in dieser (per NSPanel statt regulärer SwiftUI-WindowGroup
                // verwalteten) Fensterkonfiguration offenbar kein zuverlässiges internes Scrollen.
                // Eine simple ScrollView mit .frame(maxHeight:) nimmt aber IMMER die volle
                // Maximalhöhe ein, auch bei leerem Text – deshalb wird die natürliche Höhe des
                // Feldes per GeometryReader/PreferenceKey gemessen und die ScrollView-Höhe darauf
                // begrenzt: klein bei kurzem Text, wächst mit, ist ab maxInputHeight gedeckelt und
                // scrollt erst dann per Mausrad/Trackpad.
                ScrollView(.vertical) {
                    TextField("Frage stellen oder Screenshot senden...", text: $inputText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: InputHeightPreferenceKey.self, value: proxy.size.height)
                            }
                        )
                }
                .onPreferenceChange(InputHeightPreferenceKey.self) { newHeight in
                    inputFieldHeight = newHeight
                }
                .frame(height: min(max(inputFieldHeight, minInputHeight), maxInputHeight))
                    .padding(.horizontal, DS.Space.m)
                    .padding(.vertical, DS.Space.s)
                    // Composer als Liquid-Glass-Fläche (Phase G): Der Composer ist Steuerfläche,
                    // nicht Content – genau dort gehört Glass hin.
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
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
                    .onSubmit {
                        if showSlashCommands && !matchedCommands.isEmpty {
                            // Wenn Popover offen ist, nimm den selektierten Befehl anstatt zu senden
                            let cmd = matchedCommands[selectedCommandIndex]
                            inputText = "/" + cmd.id + " "
                            showSlashCommands = false
                            return
                        }
                        handleSend()
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
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(
            Group {
                if isHoveringDropZone {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, dash: [10]))
                        .background(Color.blue.opacity(0.1))
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
                    onDone: { annotated in
                        lastCapturedImage = annotated
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

// MARK: - InputHeightPreferenceKey

/// Reicht die gemessene natürliche Höhe des Eingabefelds nach oben durch, damit die umgebende
/// ScrollView ihre Höhe entsprechend anpassen kann (siehe InputArea.body).
private struct InputHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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
                            Text(hint).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(cmd.description).font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(index == selectedIndex ? Color.blue.opacity(0.2) : Color.clear)
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
                            .foregroundColor(.secondary)
                    }
                    Text(msg.text.isEmpty ? "[Screenshot]" : msg.text)
                        .font(.callout)
                        .lineLimit(3)
                    Spacer()
                    Button(action: { onRemove(msg.id) }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
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

