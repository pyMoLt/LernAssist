import SwiftUI
import UniformTypeIdentifiers

// MARK: - SidebarView

struct SidebarView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var expandedArchiveGroups: Set<String> = []
    @State private var isShowingGallery = false
    @State private var isArchiveSectionExpanded = true
    @State private var isTrashSectionExpanded = false
    @State private var isShowingEmptyTrashConfirmation = false
    @State private var searchText = ""
    /// Debounce-Puffer (Audit U5): Die Volltextsuche läuft über den Inhalt ALLER Sessions –
    /// vorher wurde bei jedem Tastendruck sofort gefiltert und bei vielen/langen Chats die
    /// komplette Inhaltsliste durchsucht. Gesucht wird erst 250 ms nach der letzten Eingabe.
    @State private var debouncedSearchText = ""
    @State private var searchDebounceTask: Task<Void, Never>? = nil

    /// Volltextsuche über Titel UND Nachrichteninhalt (case-insensitive) – vorher hatte die
    /// Sidebar bei vielen Chats über längere Zeit keine Möglichkeit, gezielt einen alten Chat
    /// wiederzufinden.
    private func matchesSearch(_ session: ChatSession) -> Bool {
        guard !debouncedSearchText.isEmpty else { return true }
        let q = debouncedSearchText.lowercased()
        if session.title.lowercased().contains(q) { return true }
        return session.messages.contains { $0.content.lowercased().contains(q) }
    }

    private var filteredSessions: [ChatSession] {
        // sorted(by:) ist stabil (Swift 5+) – gepinnte Chats rutschen nach oben, die relative
        // Reihenfolge innerhalb "gepinnt"/"nicht gepinnt" bleibt sonst unverändert.
        viewModel.sessions.filter(matchesSearch).sorted {
            ($0.isPinned ?? false) && !($1.isPinned ?? false)
        }
    }

    private var filteredArchivedSessions: [ChatSession] {
        viewModel.archivedSessions.filter(matchesSearch)
    }

    private var filteredTrashedSessions: [ChatSession] {
        viewModel.trashedSessions.filter(matchesSearch)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                ZStack {
                    Circle().fill(DS.Ink.accent.opacity(0.12))
                    Image(systemName: "graduationcap.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Ink.accent.gradient)
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("LernAssist")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    Text("Deine Lernräume")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.top, DS.Space.m)
            .padding(.bottom, DS.Space.s)

            // Global Screenshot Button at the top
            Button(action: { isShowingGallery = true }) {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "photo.on.rectangle.angled")
                    Text("Alle Screenshots")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.Space.s)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                        .fill(DS.Surface.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                        .stroke(DS.Ink.hairline.opacity(0.5), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, DS.Space.m)
            .padding(.bottom, DS.Space.s)

            // Volltextsuche über alle Chats (aktiv + archiviert)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Chats durchsuchen...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .onChange(of: searchText) { newValue in
                        // Debounce (Audit U5): siehe debouncedSearchText. Leerer Suchtext
                        // filtert sofort (kein künstliches Delay beim Löschen).
                        searchDebounceTask?.cancel()
                        if newValue.isEmpty {
                            debouncedSearchText = ""
                            return
                        }
                        searchDebounceTask = Task {
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            guard !Task.isCancelled else { return }
                            debouncedSearchText = newValue
                        }
                    }
                if !searchText.isEmpty {
                    Button(action: {
                        searchDebounceTask?.cancel()
                        searchText = ""
                        debouncedSearchText = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous).fill(DS.Surface.chip))
            .padding(.horizontal, DS.Space.m)
            .padding(.bottom, DS.Space.s)

            List(selection: $viewModel.activeSessionId) {
                Section {
                    ForEach(filteredSessions) { session in
                        SessionRow(
                            session: session,
                            canDelete: viewModel.sessions.count > 1,
                            onRename: { newTitle in viewModel.renameSession(id: session.id, newTitle: newTitle) },
                            onArchive: { viewModel.archiveSession(id: session.id) },
                            onDelete: { viewModel.trashSession(id: session.id) },
                            onMoveToFolder: { folder in viewModel.moveSessionToFolder(id: session.id, folder: folder) },
                            onTogglePin: { viewModel.togglePin(id: session.id) }
                        )
                        .tag(session.id)
                        .itemProvider { NSItemProvider(object: session.id.uuidString as NSString) }
                    }
                }
                .onDrop(of: [.text], isTargeted: nil) { providers in
                    handleDropToCurrent(providers: providers)
                }

                let showArchiveSection = debouncedSearchText.isEmpty
                    ? (!viewModel.archivedSessions.isEmpty || !viewModel.customArchiveFolders.isEmpty)
                    : !filteredArchivedSessions.isEmpty
                if showArchiveSection {
                    DisclosureGroup(isExpanded: $isArchiveSectionExpanded) {
                        let grouped = groupSessionsByFolder(filteredArchivedSessions)
                        // Während einer Suche nur Ordner mit tatsächlichen Treffern zeigen – sonst
                        // wäre orderedFolderKeys() (das über ALLE bekannten Ordner iteriert, auch
                        // ohne Treffer) mit leeren "Ordner (0)"-Zeilen im Suchergebnis aufgetaucht.
                        let visibleFolderKeys = orderedFolderKeys(from: grouped)
                            .filter { debouncedSearchText.isEmpty || !(grouped[$0] ?? []).isEmpty }
                        ForEach(visibleFolderKeys, id: \.self) { folderKey in
                            let sessions = grouped[folderKey] ?? []
                            DisclosureGroup(
                                isExpanded: Binding(
                                    get: { expandedArchiveGroups.contains(folderKey) },
                                    set: { isExpanded in
                                        if isExpanded { expandedArchiveGroups.insert(folderKey) }
                                        else { expandedArchiveGroups.remove(folderKey) }
                                    }
                                )
                            ) {
                                ForEach(sessions) { session in
                                    ArchivedSessionRow(
                                        session: session,
                                        onRestore: { viewModel.unarchiveSession(id: session.id) },
                                        onTrash: { viewModel.trashArchivedSession(id: session.id) },
                                        onMoveToFolder: { folder in viewModel.moveSessionToFolder(id: session.id, folder: folder) }
                                    )
                                    // Fehlte bisher: ohne itemProvider ließ sich ein bereits archivierter
                                    // Chat nicht per Drag & Drop in einen ANDEREN Ordner ziehen (nur aktive
                                    // Chats aus der Chatübersicht waren als Drag-Quelle nutzbar) – der
                                    // Ordnerwechsel war dadurch nur über das Kontextmenü möglich.
                                    .itemProvider { NSItemProvider(object: session.id.uuidString as NSString) }
                                }
                            } label: {
                                Text("\(folderKey) (\(sessions.count))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .onDrop(of: [.text], isTargeted: nil) { providers in
                                handleDrop(providers: providers, folder: folderKey)
                            }
                            .contextMenu {
                                Button("Ordner löschen") {
                                    viewModel.deleteFolder(folderKey)
                                }
                            }
                        }
                        .onMove { indices, newOffset in
                            // Die Indizes beziehen sich auf visibleFolderKeys (die ForEach-
                            // Datenquelle), nicht auf customArchiveFolders – vorher wurden sie
                            // auf das falsche Array angewendet (Audit U6): Sobald Ordner
                            // existierten, die nicht in customArchiveFolders stehen, oder eine
                            // Suche die Liste filterte, wurden die falschen Ordner verschoben.
                            var keys = visibleFolderKeys
                            keys.move(fromOffsets: indices, toOffset: newOffset)
                            viewModel.reorderArchiveFolders(keys)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text("Archiv").font(.headline)
                            Button(action: {
                                promptForNewFolder()
                            }) {
                                Image(systemName: "folder.badge.plus")
                            }
                            .buttonStyle(.plain)
                            .help("Neuen Archiv-Ordner erstellen")
                            Spacer()
                        }
                    }
                    .onDrop(of: [.text], isTargeted: nil) { providers in
                        handleDropToArchive(providers: providers)
                    }
                }

                let showTrashSection = debouncedSearchText.isEmpty
                    ? !viewModel.trashedSessions.isEmpty
                    : !filteredTrashedSessions.isEmpty
                if showTrashSection {
                    DisclosureGroup(isExpanded: $isTrashSectionExpanded) {
                        ForEach(filteredTrashedSessions) { session in
                            TrashedSessionRow(
                                session: session,
                                onRestore: { viewModel.restoreFromTrash(id: session.id) },
                                onDeletePermanently: { viewModel.deleteTrashedSessionPermanently(id: session.id) }
                            )
                        }
                    } label: {
                        Text("Papierkorb (\(viewModel.trashedSessions.count))")
                            .font(.headline)
                            .contextMenu {
                                Button(role: .destructive, action: {
                                    isShowingEmptyTrashConfirmation = true
                                }) {
                                    Label("Papierkorb leeren", systemImage: "trash.fill")
                                }
                            }
                            .alert("Papierkorb leeren?", isPresented: $isShowingEmptyTrashConfirmation) {
                                Button("Abbrechen", role: .cancel) { }
                                Button("Leeren", role: .destructive) { viewModel.emptyTrash() }
                            }
                    }
                }
            }
            .listStyle(.sidebar)

            Button(action: { viewModel.createNewChat() }) {
                Label("Neuer Chat", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Space.xs)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(DS.Space.m)
        }
        .sheet(isPresented: $isShowingGallery) {
            ScreenshotGalleryView(viewModel: viewModel)
        }
    }
    
    private func promptForNewFolder() {
        let alert = NSAlert()
        alert.messageText = "Neuer Ordner"
        alert.informativeText = "Gib den Namen des neuen Ordners ein:"
        alert.addButton(withTitle: "Erstellen")
        alert.addButton(withTitle: "Abbrechen")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        alert.accessoryView = input
        if alert.runModal() == .alertFirstButtonReturn, !input.stringValue.isEmpty {
            viewModel.addCustomArchiveFolder(input.stringValue)
        }
    }

    private func handleDrop(providers: [NSItemProvider], folder: String) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.text", options: nil) { (item, error) in
            guard let data = item as? Data,
                  let idString = String(data: data, encoding: .utf8),
                  let id = UUID(uuidString: idString) else { return }
            DispatchQueue.main.async {
                viewModel.moveSessionToFolder(id: id, folder: folder)
            }
        }
        return true
    }

    private func handleDropToCurrent(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.text", options: nil) { (item, error) in
            guard let data = item as? Data,
                  let idString = String(data: data, encoding: .utf8),
                  let id = UUID(uuidString: idString) else { return }
            DispatchQueue.main.async {
                viewModel.unarchiveSession(id: id)
            }
        }
        return true
    }

    private func handleDropToArchive(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.text", options: nil) { (item, error) in
            guard let data = item as? Data,
                  let idString = String(data: data, encoding: .utf8),
                  let id = UUID(uuidString: idString) else { return }
            DispatchQueue.main.async {
                viewModel.archiveSession(id: id)
            }
        }
        return true
    }
    
    private func orderedFolderKeys(from grouped: [String: [ChatSession]]) -> [String] {
        var keys = viewModel.customArchiveFolders
        let otherKeys = grouped.keys.filter { !keys.contains($0) }.sorted(by: >)
        keys.append(contentsOf: otherKeys)
        return keys
    }
    
    private func groupSessionsByFolder(_ sessions: [ChatSession]) -> [String: [ChatSession]] {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        formatter.locale = Locale(identifier: "de_DE")
        
        var dict = Dictionary(grouping: sessions) { session in
            session.archiveFolder ?? formatter.string(from: session.date)
        }
        for folder in viewModel.customArchiveFolders {
            if dict[folder] == nil {
                dict[folder] = []
            }
        }
        return dict
    }
}

// MARK: - SessionRow (aktive Chats: Umbenennen per Doppelklick, Archivieren, Löschen)

private struct SessionRow: View {
    let session: ChatSession
    let canDelete: Bool
    let onRename: (String) -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void
    let onMoveToFolder: (String) -> Void
    let onTogglePin: () -> Void

    @State private var isEditing = false
    @State private var draftTitle = ""
    @FocusState private var isFieldFocused: Bool

    private var isPinned: Bool { session.isPinned ?? false }

    var body: some View {
        HStack {
            Image(systemName: isPinned ? "pin.fill" : "message.fill")
                .foregroundColor(isPinned ? .orange : .blue.opacity(0.7))
                .font(.caption)

            if isEditing {
                TextField("Titel", text: $draftTitle, onCommit: commitRename)
                    .textFieldStyle(.plain)
                    .focused($isFieldFocused)
                    .onExitCommand { isEditing = false }
            } else {
                Text(session.title)
                    .lineLimit(1)
                    .onTapGesture(count: 2) { beginEditing() }
            }

            Spacer()

            if !isEditing {
                Button(action: onArchive) {
                    Image(systemName: "archivebox")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .opacity(0.6)
                .help("Chat archivieren")

                if canDelete {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .opacity(0.6)
                    .help("In den Papierkorb verschieben")
                }
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .leading) {
            Button(action: onArchive) {
                Label("Archiv", systemImage: "archivebox")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing) {
            if canDelete {
                Button(action: onDelete) {
                    Label("In Papierkorb", systemImage: "trash")
                }
                .tint(.red)
            }
        }
        .contextMenu {
            Button(isPinned ? "Pin lösen" : "Anpinnen") {
                onTogglePin()
            }
            Divider()
            Button("Ordner zuweisen...") {
                // Hier könnten wir einen Prompt-Dialog für den Ordnernamen einbauen,
                // in SwiftUI macOS geht das per popover oder alert.
                // Für diesen Prototyp:
                let alert = NSAlert()
                alert.messageText = "In welchen Ordner verschieben?"
                alert.informativeText = "Gib den Namen des Archiv-Ordners ein:"
                alert.addButton(withTitle: "Verschieben")
                alert.addButton(withTitle: "Abbrechen")
                let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
                alert.accessoryView = input
                if alert.runModal() == .alertFirstButtonReturn, !input.stringValue.isEmpty {
                    onMoveToFolder(input.stringValue)
                }
            }
        }
    }

    private func beginEditing() {
        draftTitle = session.title
        isEditing = true
        DispatchQueue.main.async { isFieldFocused = true }
    }

    private func commitRename() {
        onRename(draftTitle)
        isEditing = false
    }
}

// MARK: - ArchivedSessionRow

private struct ArchivedSessionRow: View {
    let session: ChatSession
    let onRestore: () -> Void
    let onTrash: () -> Void
    let onMoveToFolder: (String) -> Void

    var body: some View {
        HStack {
            Image(systemName: "message")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(session.title)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onRestore) {
                Image(systemName: "arrow.uturn.up")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .opacity(0.6)
            .help("Wiederherstellen")

            Button(action: onTrash) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .opacity(0.6)
            .help("In den Papierkorb verschieben")
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .leading) {
            Button(action: onRestore) {
                Label("Wiederherstellen", systemImage: "arrow.uturn.up")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing) {
            Button(action: onTrash) {
                Label("In Papierkorb", systemImage: "trash")
            }
            .tint(.red)
        }
        .contextMenu {
            Button("In anderen Ordner verschieben...") {
                let alert = NSAlert()
                alert.messageText = "In welchen Ordner verschieben?"
                alert.informativeText = "Gib den Namen des neuen Archiv-Ordners ein:"
                alert.addButton(withTitle: "Verschieben")
                alert.addButton(withTitle: "Abbrechen")
                let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
                alert.accessoryView = input
                if alert.runModal() == .alertFirstButtonReturn, !input.stringValue.isEmpty {
                    onMoveToFolder(input.stringValue)
                }
            }
        }
    }
}

// MARK: - TrashedSessionRow

private struct TrashedSessionRow: View {
    let session: ChatSession
    let onRestore: () -> Void
    let onDeletePermanently: () -> Void

    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        HStack {
            Image(systemName: "message")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(session.title)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onRestore) {
                Image(systemName: "arrow.uturn.up")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .opacity(0.6)
            .help("Wiederherstellen")

            Button(action: { isShowingDeleteConfirmation = true }) {
                Image(systemName: "trash.fill")
                    .foregroundColor(.red.opacity(0.7))
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .opacity(0.6)
            .help("Endgültig löschen")
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .leading) {
            Button(action: onRestore) {
                Label("Wiederherstellen", systemImage: "arrow.uturn.up")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing) {
            Button(action: { isShowingDeleteConfirmation = true }) {
                Label("Endgültig löschen", systemImage: "trash")
            }
            .tint(.red)
        }
        // Im Papierkorb selbst ist "endgültig löschen" wirklich unwiderruflich (keine Trash-Stufe
        // mehr darunter) – anders als das Verschieben in den Papierkorb selbst gibt es hier bewusst
        // eine Rückfrage, um genau diesen letzten, nicht mehr rückgängig zu machenden Schritt
        // abzusichern.
        .alert("Chat endgültig löschen?", isPresented: $isShowingDeleteConfirmation) {
            Button("Abbrechen", role: .cancel) {}
            Button("Endgültig löschen", role: .destructive) { onDeletePermanently() }
        } message: {
            Text("„\(session.title)“ wird unwiderruflich gelöscht. Das kann nicht rückgängig gemacht werden.")
        }
    }
}
