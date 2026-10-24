import SwiftUI
import AppKit

// MARK: - Archiv & Papierkorb als eigenes Fenster
//
// Archivierte und gelöschte Chats stehen nicht mehr dauerhaft in der Sidebar, sondern hinter zwei
// kleinen Buttons. Hier sind sie nur lesbar; „Wiederherstellen“ holt einen Chat zurück in die
// aktiven Chats. Archiv-Ordner (eigene und automatische Monatsordner) leben ebenfalls hier.

enum ArchiveBrowserMode: String {
    case archive, trash

    var title: String { self == .archive ? L("Archiv") : L("Papierkorb") }
}

@MainActor
enum ArchiveWindowController {
    private static var windows: [ArchiveBrowserMode: NSWindow] = [:]

    static func show(viewModel: ChatViewModel, mode: ArchiveBrowserMode, search: String = "") {
        if let window = windows[mode], window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = ArchiveBrowserView(viewModel: viewModel, mode: mode, initialSearch: search)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 820, height: 560)),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = mode.title
        window.titlebarAppearsTransparent = true
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(CGSize(width: 820, height: 560))
        window.minSize = CGSize(width: 560, height: 380)
        window.isReleasedWhenClosed = false
        // Das Hauptfenster schwebt (.floating) – sonst verschwände dieses Fenster dahinter.
        window.level = .floating
        window.center()
        windows[mode] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close(_ mode: ArchiveBrowserMode) {
        windows[mode]?.close()
    }
}

struct ArchiveBrowserView: View {
    @ObservedObject var viewModel: ChatViewModel
    let mode: ArchiveBrowserMode
    @State private var search: String
    @State private var selection: UUID?
    @State private var confirmDeleteID: UUID?
    @State private var confirmEmptyTrash = false

    init(viewModel: ChatViewModel, mode: ArchiveBrowserMode, initialSearch: String = "") {
        self.viewModel = viewModel
        self.mode = mode
        _search = State(initialValue: initialSearch)
    }

    private var allSessions: [ChatSession] {
        mode == .archive ? viewModel.archivedSessions : viewModel.trashedSessions
    }

    private var filtered: [ChatSession] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let list = allSessions.sorted { $0.lastActivityDate > $1.lastActivityDate }
        guard !q.isEmpty else { return list }
        return list.filter { session in
            session.title.lowercased().contains(q) || session.messages.contains { $0.content.lowercased().contains(q) }
        }
    }

    /// Archiv: Ordner (eigene zuerst, dann automatische Monatsordner). Papierkorb: eine Gruppe.
    private var groups: [(title: String, sessions: [ChatSession])] {
        guard mode == .archive else { return [("", filtered)] }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        formatter.locale = Locale(identifier: "de_DE")
        let grouped = Dictionary(grouping: filtered) { $0.archiveFolder ?? formatter.string(from: $0.date) }
        var keys = viewModel.customArchiveFolders.filter { grouped[$0] != nil || search.isEmpty }
        let auto = grouped.keys.filter { !keys.contains($0) }.sorted { lhs, rhs in
            (grouped[lhs]?.first?.date ?? .distantPast) > (grouped[rhs]?.first?.date ?? .distantPast)
        }
        keys.append(contentsOf: auto)
        return keys.map { ($0, grouped[$0] ?? []) }
    }

    private var selectedSession: ChatSession? {
        allSessions.first { $0.id == selection }
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 230, idealWidth: 270, maxWidth: 360)
            detail
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 560, minHeight: 380)
        .background(DS.Surface.canvas)
        .alert(L("Chat endgültig löschen?"), isPresented: Binding(get: { confirmDeleteID != nil }, set: { if !$0 { confirmDeleteID = nil } })) {
            Button(L("Abbrechen"), role: .cancel) {}
            Button(L("Endgültig löschen"), role: .destructive) {
                if let id = confirmDeleteID { viewModel.deleteTrashedSessionPermanently(id: id) }
                if selection == confirmDeleteID { selection = nil }
            }
        } message: {
            Text(L("Das kann nicht rückgängig gemacht werden."))
        }
        .alert(L("Papierkorb leeren?"), isPresented: $confirmEmptyTrash) {
            Button(L("Abbrechen"), role: .cancel) {}
            Button(L("Leeren"), role: .destructive) { viewModel.emptyTrash(); selection = nil }
        } message: {
            Text(L("Alle \(viewModel.trashedSessions.count) Chats werden unwiderruflich gelöscht."))
        }
    }

    // MARK: Liste

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField(L("\(mode.title) durchsuchen …"), text: $search)
                    .textFieldStyle(.plain)
                    .font(.caption)
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous).fill(DS.Surface.chip))
            .padding([.horizontal, .top], DS.Space.m)
            .padding(.top, 22)

            if filtered.isEmpty {
                Spacer()
                VStack(spacing: DS.Space.s) {
                    Image(systemName: mode == .archive ? "archivebox" : "trash")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(search.isEmpty ? (mode == .archive ? L("Keine archivierten Chats") : L("Der Papierkorb ist leer")) : L("Keine Treffer"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List(selection: $selection) {
                    ForEach(groups, id: \.title) { group in
                        Section {
                            ForEach(group.sessions) { session in
                                row(session).tag(session.id)
                            }
                        } header: {
                            if !group.title.isEmpty {
                                Text("\(group.title) · \(group.sessions.count)")
                                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.tertiary)
                                    .contextMenu {
                                        if viewModel.customArchiveFolders.contains(group.title) {
                                            Button(L("Ordner auflösen")) { viewModel.deleteFolder(group.title) }
                                        }
                                    }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }

            HStack {
                if mode == .archive {
                    Button {
                        if let name = FolderPrompt.ask(title: L("Neuer Archiv-Ordner")) { viewModel.addCustomArchiveFolder(name) }
                    } label: {
                        Label(L("Neuer Ordner"), systemImage: "folder.badge.plus").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Text(L("Automatisch nach 7 Tagen ohne Aktivität"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Spacer()
                    Button(L("Papierkorb leeren")) { confirmEmptyTrash = true }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(viewModel.trashedSessions.isEmpty ? Color.secondary : Color.red)
                        .disabled(viewModel.trashedSessions.isEmpty)
                }
            }
            .padding(DS.Space.m)
        }
        .background(DS.Surface.sidebar)
    }

    private func row(_ session: ChatSession) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.displayTitle)
                .font(.system(size: 12.5, design: .rounded))
                .lineLimit(1)
            Text(session.lastActivityDate.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(Locale(identifier: Loc.current == .english ? "en_US" : "de_DE"))))
                .font(.system(size: 10.5, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(L("Wiederherstellen")) { restore(session.id) }
            if mode == .archive {
                Button(L("In Ordner verschieben …")) {
                    if let folder = FolderPrompt.ask(title: L("In welchen Archiv-Ordner?")) {
                        viewModel.moveSessionToFolder(id: session.id, folder: folder)
                    }
                }
                Divider()
                Button(L("In den Papierkorb"), role: .destructive) { viewModel.trashArchivedSession(id: session.id) }
            } else {
                Divider()
                Button(L("Endgültig löschen"), role: .destructive) { confirmDeleteID = session.id }
            }
        }
    }

    // MARK: Vorschau (nur lesen)

    @ViewBuilder
    private var detail: some View {
        if let session = selectedSession {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: DS.Space.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.displayTitle)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                        Text(L("\(session.messages.filter { $0.role == "user" || $0.role == "assistant" }.count) Nachrichten · nur lesen"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if mode == .archive {
                        Button(role: .destructive) { viewModel.trashArchivedSession(id: session.id); selection = nil } label: {
                            Label(L("Papierkorb"), systemImage: "trash")
                        }
                        .buttonStyle(SoftActionButtonStyle(tint: DS.Ink.primary))
                    } else {
                        Button(role: .destructive) { confirmDeleteID = session.id } label: {
                            Label(L("Endgültig löschen"), systemImage: "trash")
                        }
                        .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.rose))
                    }
                    Button { restore(session.id) } label: {
                        Label(L("Wiederherstellen"), systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(SoftActionButtonStyle(tint: DS.Ink.accent, prominent: true))
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.top, 30)
                .padding(.bottom, DS.Space.m)

                Divider().opacity(0.4)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.m) {
                        ForEach(session.messages.filter { ($0.role == "user" || $0.role == "assistant") && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { message in
                            ArchivedMessageView(message: message)
                        }
                    }
                    .padding(DS.Space.l)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        } else {
            VStack(spacing: DS.Space.s) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(L("Chat auswählen, um ihn zu lesen"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func restore(_ id: UUID) {
        if mode == .archive { viewModel.unarchiveSession(id: id) } else { viewModel.restoreFromTrash(id: id) }
        selection = nil
        // Wiederhergestellter Chat ist aktiv – Hauptfenster zeigen.
        (NSApp.delegate as? AppDelegate)?.showWindow()
    }
}

/// Schlanke, schreibgeschützte Darstellung einer Nachricht (ohne WebView: schnell bei langen
/// Chats). Überschriften, Aufzählungen und Inline-Markdown werden einfach gesetzt.
private struct ArchivedMessageView: View {
    let message: ChatMessage

    var body: some View {
        let isUser = message.role == "user"
        HStack {
            if isUser { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(Self.blocks(message.displayText ?? message.content).enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .textSelection(.enabled)
            .padding(isUser ? DS.Space.s + 2 : 0)
            .padding(.horizontal, isUser ? 4 : 0)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                    .fill(isUser ? DS.Surface.bubbleUser : Color.clear)
            )
            if !isUser { Spacer(minLength: 0) }
        }
    }

    private enum Block {
        case heading(String)
        case bullet(String)
        case paragraph(String)
        case code(String)
    }

    private static func blocks(_ text: String) -> [Block] {
        var result: [Block] = []
        var inCode = false
        var code: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inCode { result.append(.code(code.joined(separator: "\n"))); code = [] }
                inCode.toggle()
                continue
            }
            if inCode { code.append(raw); continue }
            if line.isEmpty || line == "---" { continue }
            if line.hasPrefix("#") {
                result.append(.heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("* ") || line.hasPrefix("- ") || line.hasPrefix("• ") {
                result.append(.bullet(String(line.dropFirst(2))))
            } else {
                result.append(.paragraph(line))
            }
        }
        if inCode, !code.isEmpty { result.append(.code(code.joined(separator: "\n"))) }
        return result
    }

    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
             ?? AttributedString(text))
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let text):
            inline(text)
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .padding(.top, 4)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                inline(text).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 13, design: .rounded))
        case .paragraph(let text):
            inline(text)
                .font(.system(size: 13, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
        case .code(let text):
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .padding(DS.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous).fill(DS.Surface.chip))
        }
    }
}
