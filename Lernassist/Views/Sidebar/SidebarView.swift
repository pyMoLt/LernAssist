import SwiftUI
import UniformTypeIdentifiers

// MARK: - SidebarView

struct SidebarView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var isShowingGallery = false
    @State private var searchText = ""
    /// Debounce-Puffer (Audit U5): Die Volltextsuche läuft über den Inhalt ALLER Sessions –
    /// gesucht wird erst 250 ms nach der letzten Eingabe.
    @State private var debouncedSearchText = ""
    @State private var searchDebounceTask: Task<Void, Never>? = nil
    @State private var isArchiveDropTargeted = false
    /// Fach-Filter (nil = alle Fächer).
    @State private var subjectFilter: String?

    /// Volltextsuche über Titel UND Nachrichteninhalt (case-insensitive).
    private func matchesSearch(_ session: ChatSession) -> Bool {
        guard !debouncedSearchText.isEmpty else { return true }
        let q = debouncedSearchText.lowercased()
        if session.title.lowercased().contains(q) { return true }
        return session.messages.contains { $0.content.lowercased().contains(q) }
    }

    /// Aktive Chats in Zeitgruppen (Angepinnt · Heute · Gestern · Diese Woche · Älter).
    private var sessionGroups: [(title: String, sessions: [ChatSession])] {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let startOfWeek = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday

        var pinned: [ChatSession] = [], today: [ChatSession] = [], yesterday: [ChatSession] = []
        var week: [ChatSession] = [], older: [ChatSession] = []
        let sorted = viewModel.sessions
            .filter(matchesSearch)
            .filter { subjectFilter == nil || $0.subject?.lowercased() == subjectFilter?.lowercased() }
            .sorted { $0.lastActivityDate > $1.lastActivityDate }
        for session in sorted {
            let date = session.lastActivityDate
            if session.isPinned ?? false { pinned.append(session) }
            else if date >= startOfToday { today.append(session) }
            else if date >= startOfYesterday { yesterday.append(session) }
            else if date >= startOfWeek { week.append(session) }
            else { older.append(session) }
        }
        return [(L("Angepinnt"), pinned), (L("Heute"), today), (L("Gestern"), yesterday), (L("Diese Woche"), week), (L("Älter"), older)]
            .filter { !$0.sessions.isEmpty }
    }

    private var archiveSearchHits: Int {
        debouncedSearchText.isEmpty ? 0 : viewModel.archivedSessions.filter(matchesSearch).count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            galleryButton
            searchField
            subjectChips

            List(selection: $viewModel.activeSessionId) {
                ForEach(sessionGroups, id: \.title) { group in
                    Section {
                        ForEach(group.sessions) { session in
                            // Dezente Scrollleiste der Chat-Liste (liegt in der List, findet deren ScrollView).
                            SessionRow(
                                session: session,
                                canDelete: viewModel.sessions.count > 1,
                                onRename: { newTitle in viewModel.renameSession(id: session.id, newTitle: newTitle) },
                                onArchive: { viewModel.archiveSession(id: session.id) },
                                onDelete: { viewModel.trashSession(id: session.id) },
                                onMoveToFolder: { folder in viewModel.moveSessionToFolder(id: session.id, folder: folder) },
                                onTogglePin: { viewModel.togglePin(id: session.id) },
                                onSetSubject: {
                                    if let subject = FolderPrompt.ask(title: L("Fach für „\(session.title)“"),
                                                                       message: L("Allgemeines Fach, z. B. Physiologie oder Algorithmen. Leer lassen = KI entscheidet."),
                                                                       initial: session.subject ?? "", allowEmpty: true) {
                                        viewModel.setSubject(id: session.id, subject: subject)
                                    }
                                }
                            )
                            .background(DiscreetScrollers())
                            .tag(session.id)
                            .itemProvider { NSItemProvider(object: session.id.uuidString as NSString) }
                        }
                    } header: {
                        Text(group.title)
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                }
                if archiveSearchHits > 0 {
                    Button {
                        ArchiveWindowController.show(viewModel: viewModel, mode: .archive, search: debouncedSearchText)
                    } label: {
                        Label(L("\(archiveSearchHits) Treffer im Archiv"), systemImage: "archivebox")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onDrop(of: [.text], isTargeted: nil) { providers in
                handleDrop(providers) { viewModel.unarchiveSession(id: $0) }
            }

            footer
        }
        // Version 4: Seitenleiste als schwebende Karte über dem Farbfeld (Vorlage). Sie reicht bis
        // nach oben; die Fensterknöpfe liegen in der Karte, der Inhalt beginnt darunter.
        .padding(.top, 28)
        .glassSurface(cornerRadius: 11, elevated: true)
        .padding(.leading, 6)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .sheet(isPresented: $isShowingGallery) {
            ScreenshotGalleryView(viewModel: viewModel)
        }
    }

    // MARK: Kopf

    private var header: some View {
        HStack(spacing: DS.Space.s + 2) {
            LernAssistBrandIcon(size: 28)
            Text(L("LernAssist"))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            SidebarIconButton(systemImage: "square.and.pencil", help: L("Neuer Chat (⌘N)")) {
                viewModel.createNewChat()
            }
            .accessibilityLabel(L("Neuer Chat"))
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.top, DS.Space.m)
        .padding(.bottom, DS.Space.s + 2)
    }

    private var galleryButton: some View {
        Button(action: { isShowingGallery = true }) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Ink.accent)
                    .frame(width: 18)
                Text(L("Alle Screenshots"))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, DS.Space.s + 2)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous).fill(DS.Surface.control))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DS.Space.m)
        .padding(.bottom, DS.Space.s)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField(L("Chats durchsuchen …"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.caption)
                .onChange(of: searchText) { _, newValue in
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
                .accessibilityLabel(L("Suche leeren"))
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous).fill(DS.Surface.chip))
        .padding(.horizontal, DS.Space.m)
        .padding(.bottom, DS.Space.xs)
    }

    // MARK: Fach-Filter

    /// Fächer der aktiven Chats, häufigste zuerst.
    private var activeSubjects: [String] {
        var counts: [String: (name: String, count: Int)] = [:]
        for subject in viewModel.sessions.compactMap(\.subject) where !subject.isEmpty {
            let key = subject.lowercased()
            counts[key] = (counts[key]?.name ?? subject, (counts[key]?.count ?? 0) + 1)
        }
        return counts.values.sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }.map(\.name)
    }

    @ViewBuilder
    private var subjectChips: some View {
        let subjects = activeSubjects
        if !subjects.isEmpty {
            HStack(spacing: 0) {
                Menu {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { subjectFilter = nil }
                    } label: {
                        if subjectFilter == nil {
                            Label(L("Alle"), systemImage: "checkmark")
                        } else {
                            Text(L("Alle"))
                        }
                    }
                    Divider()
                    ForEach(subjects, id: \.self) { subject in
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { subjectFilter = subject }
                        } label: {
                            if subjectFilter?.lowercased() == subject.lowercased() {
                                Label(subject, systemImage: "checkmark")
                            } else {
                                Text(subject)
                            }
                        }
                    }
                } label: {
                    Text(subjectFilter ?? L("Alle"))
                        .font(.system(size: 11, weight: subjectFilter == nil ? .medium : .semibold, design: .rounded))
                        .foregroundStyle(subjectFilter == nil ? .secondary : DS.Ink.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(subjectFilter == nil ? DS.Surface.chip : DS.Surface.selection))
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(L("Fach-Filter: \(subjectFilter ?? L("Alle"))"))

                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.bottom, DS.Space.xs)
        }
    }

    // MARK: Fuß: Archiv & Papierkorb

    private var footer: some View {
        HStack(spacing: DS.Space.xs) {
            SidebarFooterButton(title: L("Archiv"), systemImage: "archivebox",
                                count: viewModel.archivedSessions.count, highlighted: isArchiveDropTargeted) {
                ArchiveWindowController.show(viewModel: viewModel, mode: .archive)
            }
            // Chats per Drag & Drop direkt archivieren.
            .onDrop(of: [.text], isTargeted: $isArchiveDropTargeted) { providers in
                handleDrop(providers) { viewModel.archiveSession(id: $0) }
            }
            SidebarFooterButton(title: L("Papierkorb"), systemImage: "trash",
                                count: viewModel.trashedSessions.count, highlighted: false) {
                ArchiveWindowController.show(viewModel: viewModel, mode: .trash)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.s)
    }

    private func handleDrop(_ providers: [NSItemProvider], perform: @escaping (UUID) -> Void) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.text", options: nil) { item, _ in
            guard let data = item as? Data,
                  let idString = String(data: data, encoding: .utf8),
                  let id = UUID(uuidString: idString) else { return }
            DispatchQueue.main.async { perform(id) }
        }
        return true
    }
}

/// Kleiner runder Symbol-Button (Sidebar-Kopf).
private struct SidebarIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHovered ? DS.Ink.accent : .secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(isHovered ? DS.Surface.chipHover : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovered = $0 }
    }
}

/// Dezenter Fuß-Button mit Zähler (Archiv, Papierkorb).
private struct SidebarFooterButton: View {
    let title: String
    let systemImage: String
    let count: Int
    let highlighted: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .lineLimit(1)
            .foregroundStyle(isHovered || highlighted ? DS.Ink.accent : .secondary)
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, 5)
            .background(Capsule().fill(isHovered || highlighted ? DS.Surface.chipHover : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L("\(title) öffnen"))
        .accessibilityLabel(count > 0 ? L("\(title), \(count) Chats") : title)
        .onHover { isHovered = $0 }
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
    var onSetSubject: (() -> Void)? = nil

    @State private var isEditing = false
    @State private var draftTitle = ""
    @FocusState private var isFieldFocused: Bool

    private var isPinned: Bool { session.isPinned ?? false }

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DS.Space.s) {
            if isPinned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(DS.Ink.accent)
                    .font(.system(size: 9))
            }
            if isEditing {
                TextField(L("Titel"), text: $draftTitle, onCommit: commitRename)
                    .textFieldStyle(.plain)
                    .focused($isFieldFocused)
                    .onExitCommand { isEditing = false }
            } else {
                Text(session.displayTitle)
                    .font(.system(size: 12.5, design: .rounded))
                    .lineLimit(1)
                    .onTapGesture(count: 2) { beginEditing() }
            }
            Spacer(minLength: 0)
            // Nur beim Überfahren: Archivieren. Alles Weitere per Rechtsklick.
            if isHovered && !isEditing {
                Button(action: onArchive) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Archivieren"))
                .accessibilityLabel(L("Chat archivieren"))
                .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering } }
        .swipeActions(edge: .leading) {
            Button(action: onArchive) { Label(L("Archiv"), systemImage: "archivebox") }
                .tint(DS.Ink.accent)
        }
        .swipeActions(edge: .trailing) {
            if canDelete {
                Button(action: onDelete) { Label(L("In Papierkorb"), systemImage: "trash") }
                    .tint(.red)
            }
        }
        .contextMenu {
            Button(L("Umbenennen")) { beginEditing() }
            Button(isPinned ? L("Nicht mehr anpinnen") : L("Anpinnen")) { onTogglePin() }
            if let onSetSubject {
                Button(session.subject.map { "Fach ändern (\($0)) …" } ?? L("Fach festlegen …")) { onSetSubject() }
            }
            Divider()
            Button(L("Archivieren")) { onArchive() }
            Button(L("In Archiv-Ordner …")) {
                if let folder = FolderPrompt.ask(title: L("In welchen Archiv-Ordner?")) { onMoveToFolder(folder) }
            }
            if canDelete {
                Divider()
                Button(L("In den Papierkorb"), role: .destructive) { onDelete() }
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

// MARK: - Ordnername abfragen

enum FolderPrompt {
    static func ask(title: String, message: String = L("Name des Archiv-Ordners:"), initial: String = "", allowEmpty: Bool = false) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L("OK"))
        alert.addButton(withTitle: L("Abbrechen"))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.stringValue = initial
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        guard ModalActivity.run({ alert.runModal() }) == .alertFirstButtonReturn else { return nil }
        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty && !allowEmpty ? nil : name
    }
}
