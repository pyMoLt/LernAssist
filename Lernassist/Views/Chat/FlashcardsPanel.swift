import SwiftUI

// MARK: - Karteikarten-Panel
//
// Abfragen passiert im Chat (Quizkarten). Dieses Panel ist nur für Karteikarten: fällige Karten
// wiederholen (FSRS, über alle Chats), alle Karten ansehen/bearbeiten/anlegen/erzeugen und das
// Fehlerlog mit „Training aus Fehlern“.

struct FlashcardsPanel: View {
    @ObservedObject var viewModel: ChatViewModel
    /// Dokument-Seed: Karten direkt aus einem Dokument erzeugen (Dokument-Badge → „Karten“).
    var documentSeed: String? = nil
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case review = "Wiederholen", cards = "Alle Karten", mistakes = "Fehlerlog"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .review:   return "arrow.trianglehead.2.clockwise"
            case .cards:    return "rectangle.stack"
            case .mistakes: return "exclamationmark.bubble"
            }
        }
    }

    @State private var tab: Tab = .review

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            Divider().opacity(0.4)
            Group {
                switch tab {
                case .review:   FlashcardReviewView(viewModel: viewModel)
                case .cards:    FlashcardLibraryView(viewModel: viewModel, documentSeed: documentSeed)
                case .mistakes: MistakeLogView(viewModel: viewModel, onStartTraining: { dismiss() })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 520, idealWidth: 720, maxWidth: 900, minHeight: 440, idealHeight: 580, maxHeight: 760)
        .background(DS.Surface.canvas)
        .onAppear {
            // Ohne fällige Karten öffnet „Wiederholen“ direkt mit „Frei üben“; ganz ohne Karten
            // geht es zur Bibliothek, wo man welche anlegen oder erzeugen kann.
            if documentSeed != nil || viewModel.allFlashcardsWithContext.isEmpty { tab = .cards }
        }
    }

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.Ink.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Karteikarten")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(viewModel.dueFlashcardsCount > 0 ? "\(viewModel.dueFlashcardsCount) fällig" : "Nichts fällig")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(DS.Surface.chip))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Schließen")
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.top, DS.Space.l)
        .padding(.bottom, DS.Space.s)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { item in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { tab = item }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.icon).font(.system(size: 11, weight: .semibold))
                        Text(item.rawValue).font(.system(size: 12, weight: tab == item ? .semibold : .medium, design: .rounded))
                        if item == .review, viewModel.dueFlashcardsCount > 0 {
                            badge(viewModel.dueFlashcardsCount)
                        } else if item == .mistakes, !viewModel.openMistakes.isEmpty {
                            badge(viewModel.openMistakes.count)
                        }
                    }
                    .foregroundStyle(tab == item ? DS.Ink.accent : .secondary)
                    .padding(.horizontal, DS.Space.m)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(tab == item ? DS.Surface.selection : Color.clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.bottom, DS.Space.s)
    }

    private func badge(_ count: Int) -> some View {
        Text("\(min(count, 999))")
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(DS.Ink.accent))
    }
}

// MARK: - Wiederholen

/// Auswahl-Chip im Stil der Tab-Leiste (statt AppKit-Segmented-Control).
struct ChoiceChip: View {
    let title: String
    var icon: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 10.5, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: isSelected ? .semibold : .medium, design: .rounded))
            }
            .foregroundStyle(isSelected ? DS.Ink.accent : .secondary)
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, 5)
            .background(Capsule().fill(isSelected ? DS.Surface.selection : DS.Surface.chip))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct FlashcardReviewView: View {
    @ObservedObject var viewModel: ChatViewModel

    enum Mode { case due, practice }

    @State private var mode: Mode = .due
    @State private var queue: [ChatViewModel.DueFlashcard] = []
    @State private var isRevealed = false
    @State private var reviewedCount = 0
    /// Freies Üben: Auswahl, laufende Runde und Ergebnis.
    @State private var options = ChatViewModel.PracticeOptions()
    @State private var practiceRunning = false
    @State private var knownCount = 0

    private var current: ChatViewModel.DueFlashcard? { queue.first }

    var body: some View {
        VStack(spacing: DS.Space.l) {
            HStack(spacing: DS.Space.xs) {
                ChoiceChip(title: viewModel.dueFlashcardsCount > 0 ? "Fällig (\(viewModel.dueFlashcardsCount))" : "Fällig",
                           icon: "clock", isSelected: mode == .due) { switchMode(.due) }
                ChoiceChip(title: "Frei üben", icon: "shuffle", isSelected: mode == .practice) { switchMode(.practice) }
                Spacer()
                if mode == .practice, practiceRunning {
                    Button("Runde beenden") { endPractice() }
                        .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.rose))
                }
            }

            if let item = current {
                HStack {
                    Label(item.sessionTitle, systemImage: "text.bubble")
                        .lineLimit(1)
                    Spacer()
                    if mode == .practice {
                        Text("Frei üben · ändert keine Planung").foregroundStyle(.tertiary)
                    }
                    Text("\(queue.count) übrig")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                FlashcardFace(card: item.card, isRevealed: isRevealed)
                    .onTapGesture { withAnimation(.snappy(duration: 0.25)) { isRevealed.toggle() } }

                if isRevealed {
                    if mode == .due { dueRatingButtons(item) } else { practiceButtons(item) }
                } else {
                    Button { withAnimation(.snappy(duration: 0.25)) { isRevealed = true } } label: {
                        Text("Antwort zeigen")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(SoftActionButtonStyle(tint: DS.Ink.accent, prominent: true))
                    .keyboardShortcut(.space, modifiers: [])
                }
                Text(mode == .due ? "Leertaste: Antwort · 1–4: bewerten" : "Leertaste: Antwort · 1: Nochmal · 2: Gewusst")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if mode == .practice && !practiceRunning {
                PracticeSetupView(viewModel: viewModel, options: $options, onStart: startPractice)
            } else {
                Spacer()
                VStack(spacing: DS.Space.s) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(DS.Ink.accent)
                    Text(finishedTitle)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    if mode == .due {
                        Text(nextDueText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Button("Neue Runde") { practiceRunning = false }
                            .buttonStyle(SoftActionButtonStyle(tint: DS.Ink.accent, prominent: true))
                    }
                }
                Spacer()
            }
        }
        .padding(DS.Space.l)
        .onAppear {
            if viewModel.dueFlashcardsCount == 0 { mode = .practice }
            reload()
        }
    }

    private var finishedTitle: String {
        if mode == .practice { return "Runde beendet – \(knownCount) von \(reviewedCount) gewusst" }
        return reviewedCount > 0 ? "Geschafft – \(reviewedCount) Karten wiederholt" : "Keine Karte fällig"
    }

    private func dueRatingButtons(_ item: ChatViewModel.DueFlashcard) -> some View {
        HStack(spacing: DS.Space.s) {
            ForEach(FlashcardRating.allCases) { rating in
                Button { rate(item, rating) } label: {
                    VStack(spacing: 2) {
                        Text(rating.label).font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        Text(preview(item.card, rating)).font(.system(size: 10.5, design: .rounded)).opacity(0.75)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(ratingColor(rating))
                    .background(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous).fill(ratingColor(rating).opacity(0.12)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character(String(rating.grade))), modifiers: [])
                .help("\(rating.label) (Taste \(rating.grade))")
            }
        }
        .transition(.opacity)
    }

    /// Freies Üben: nur „Nochmal“ (kommt am Ende der Runde wieder) und „Gewusst“.
    private func practiceButtons(_ item: ChatViewModel.DueFlashcard) -> some View {
        HStack(spacing: DS.Space.s) {
            practiceButton("Nochmal", tint: DS.Accent.rose, key: "1") { advancePractice(item, known: false) }
            practiceButton("Gewusst", tint: DS.Accent.emerald, key: "2") { advancePractice(item, known: true) }
        }
        .transition(.opacity)
    }

    private func practiceButton(_ title: String, tint: Color, key: Character, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(tint)
                .background(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous).fill(tint.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(key), modifiers: [])
        .help("\(title) (Taste \(key))")
    }

    private var nextDueText: String {
        let future = viewModel.flashcardDueDates.filter { $0 > Date() }
        guard let next = future.min() else {
            return "Merke dir Karten über „Als Karte merken“ unter einer Antwort oder lege sie unter „Alle Karten“ an."
        }
        return "Nächste Karte fällig " + next.formatted(.relative(presentation: .named).locale(Locale(identifier: "de_DE"))) + "."
    }

    private func switchMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        withAnimation(.snappy(duration: 0.2)) {
            mode = newMode
            practiceRunning = false
            reviewedCount = 0
            knownCount = 0
            reload()
        }
    }

    private func reload() {
        queue = mode == .due ? viewModel.dueFlashcards : []
        isRevealed = false
    }

    private func startPractice() {
        let cards = ChatViewModel.practiceCards(from: viewModel.allFlashcardsWithContext, options: options,
                                                activeSessionId: viewModel.activeSessionId)
        guard !cards.isEmpty else { return }
        withAnimation(.snappy(duration: 0.25)) {
            queue = cards
            reviewedCount = 0
            knownCount = 0
            isRevealed = false
            practiceRunning = true
        }
    }

    private func endPractice() {
        withAnimation(.snappy(duration: 0.2)) { queue.removeAll() }
    }

    /// Ändert nichts an der Karte: keine FSRS-Planung, kein Fehlerlog.
    private func advancePractice(_ item: ChatViewModel.DueFlashcard, known: Bool) {
        reviewedCount += 1
        if known { knownCount += 1 }
        withAnimation(.snappy(duration: 0.25)) {
            queue.removeFirst()
            if !known { queue.append(item) }
            isRevealed = false
        }
    }

    private func rate(_ item: ChatViewModel.DueFlashcard, _ rating: FlashcardRating) {
        viewModel.recordFlashcardReview(sessionId: item.sessionId, setId: item.setId, cardId: item.card.id, rating: rating)
        reviewedCount += 1
        withAnimation(.snappy(duration: 0.25)) {
            queue.removeFirst()
            // „Nochmal“: dieselbe Karte kommt in dieser Runde später noch einmal.
            if rating == .again, let updated = viewModel.allFlashcardsWithContext.first(where: { $0.card.id == item.card.id }) {
                queue.append(updated)
            }
            isRevealed = false
        }
    }

    private func preview(_ card: Flashcard, _ rating: FlashcardRating) -> String {
        var copy = card
        copy.applyReview(rating, scheduler: FSRS(desiredRetention: viewModel.flashcardRetention), againDelayMinutes: viewModel.flashcardAgainDelayMinutes)
        let seconds = copy.dueDate.timeIntervalSinceNow
        if seconds < 3600 { return "\(max(1, Int(seconds / 60))) min" }
        let days = Int((seconds / 86_400).rounded())
        if days < 31 { return "\(max(1, days)) T" }
        if days < 365 { return "\(days / 30) Mon" }
        return String(format: "%.1f J", Double(days) / 365)
    }

    private func ratingColor(_ rating: FlashcardRating) -> Color {
        switch rating {
        case .again: return DS.Accent.rose
        case .hard:  return DS.Accent.amber
        case .good:  return DS.Accent.emerald
        case .easy:  return DS.Accent.blue
        }
    }
}

/// Auswahl für eine freie Übungsrunde: Quelle (Chat, alle, Fächer, einzelne Chats), Kartenart, Anzahl.
private struct PracticeSetupView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Binding var options: ChatViewModel.PracticeOptions
    let onStart: () -> Void

    private enum SourceKind { case currentChat, all, subjects, chats }

    private var allCards: [ChatViewModel.DueFlashcard] { viewModel.allFlashcardsWithContext }

    private var sourceKind: SourceKind {
        switch options.source {
        case .currentChat: .currentChat
        case .all: .all
        case .subjects: .subjects
        case .chats: .chats
        }
    }

    /// Fächer, zu denen es Karten gibt, mit Kartenzahl.
    private var subjects: [(name: String, count: Int)] {
        Dictionary(grouping: allCards.compactMap(\.sessionSubject), by: { $0 })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Chats mit Karten, mit Kartenzahl.
    private var chats: [(id: UUID, title: String, count: Int)] {
        Dictionary(grouping: allCards, by: \.sessionId)
            .compactMap { id, items in items.first.map { (id, $0.sessionTitle, items.count) } }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var matchingCount: Int {
        var unlimited = options
        unlimited.limit = nil
        return ChatViewModel.practiceCards(from: allCards, options: unlimited, activeSessionId: viewModel.activeSessionId).count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                section("Quelle") {
                    HStack(spacing: DS.Space.xs) {
                        ChoiceChip(title: "Dieser Chat", isSelected: sourceKind == .currentChat) { options.source = .currentChat }
                            .disabled(viewModel.activeSessionId == nil)
                        ChoiceChip(title: "Alle Chats", isSelected: sourceKind == .all) { options.source = .all }
                        ChoiceChip(title: "Fächer", isSelected: sourceKind == .subjects) {
                            if sourceKind != .subjects { options.source = .subjects([]) }
                        }
                        .disabled(subjects.isEmpty)
                        ChoiceChip(title: "Chats", isSelected: sourceKind == .chats) {
                            if sourceKind != .chats { options.source = .chats([]) }
                        }
                    }
                    if case .subjects(let selected) = options.source {
                        FlowChips(items: subjects.map { ($0.name, "\($0.name) · \($0.count)") }, selected: selected) { name in
                            var next = selected
                            if next.contains(name) { next.remove(name) } else { next.insert(name) }
                            options.source = .subjects(next)
                        }
                    }
                    if case .chats(let selected) = options.source {
                        VStack(spacing: 1) {
                            ForEach(chats, id: \.id) { chat in
                                let isOn = selected.contains(chat.id)
                                Button {
                                    var next = selected
                                    if isOn { next.remove(chat.id) } else { next.insert(chat.id) }
                                    options.source = .chats(next)
                                } label: {
                                    HStack(spacing: DS.Space.s) {
                                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(isOn ? DS.Ink.accent : .secondary.opacity(0.5))
                                        Text(chat.title).lineLimit(1)
                                        Spacer()
                                        Text("\(chat.count)").foregroundStyle(.tertiary)
                                    }
                                    .font(.system(size: 12.5, design: .rounded))
                                    .padding(.horizontal, DS.Space.s)
                                    .padding(.vertical, 6)
                                    .background(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                                        .fill(isOn ? DS.Surface.selection : Color.clear))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(maxHeight: 180)
                    }
                }

                section("Karten") {
                    HStack(spacing: DS.Space.xs) {
                        ChoiceChip(title: "Alle", isSelected: !options.onlyMistakes) { options.onlyMistakes = false }
                        ChoiceChip(title: "Nur Fehler", icon: "exclamationmark.circle", isSelected: options.onlyMistakes) { options.onlyMistakes = true }
                    }
                }

                section("Anzahl") {
                    HStack(spacing: DS.Space.xs) {
                        ForEach([10, 20, 50], id: \.self) { n in
                            ChoiceChip(title: "\(n)", isSelected: options.limit == n) { options.limit = n }
                        }
                        ChoiceChip(title: "Alle", isSelected: options.limit == nil) { options.limit = nil }
                    }
                }

                HStack {
                    Text(matchingCount == 1 ? "1 Karte passt" : "\(matchingCount) Karten passen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: onStart) {
                        Label("Runde starten", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                    .buttonStyle(SoftActionButtonStyle(tint: DS.Ink.accent, prominent: true))
                    .disabled(matchingCount == 0)
                    .keyboardShortcut(.defaultAction)
                }
                Text("Freies Üben ändert nichts an der Wiederholungsplanung.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }
}

/// Mehrfachauswahl als umbrechende Chips.
private struct FlowChips: View {
    let items: [(id: String, title: String)]
    let selected: Set<String>
    let toggle: (String) -> Void

    var body: some View {
        FlowLayout(spacing: DS.Space.xs) {
            ForEach(items, id: \.id) { item in
                ChoiceChip(title: item.title, isSelected: selected.contains(item.id)) { toggle(item.id) }
            }
        }
    }
}

/// Einfaches Umbruch-Layout für Chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Vorder-/Rückseite einer Karte; bei Abdeckkarten das Bild mit verdecktem oder markiertem Bereich.
struct FlashcardFace: View {
    let card: Flashcard
    let isRevealed: Bool

    var body: some View {
        VStack(spacing: DS.Space.m) {
            if let imageID = card.imageID {
                if let rect = card.occlusion, rect.count == 4 {
                    OcclusionImageView(imageID: imageID, rect: rect, isRevealed: isRevealed)
                        .frame(maxHeight: 260)
                } else {
                    CardImageView(imageID: imageID)
                        .frame(maxHeight: 240)
                }
            }
            Text(card.front)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if isRevealed {
                Divider().opacity(0.5)
                Text(card.back)
                    .font(.system(size: 14.5, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .textSelection(.enabled)
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, minHeight: 200)
        .background(RoundedRectangle(cornerRadius: DS.Radius.extraLarge, style: .continuous).fill(DS.Surface.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.extraLarge, style: .continuous).stroke(DS.Ink.hairline, lineWidth: 0.75))
        .contentShape(Rectangle())
    }
}

/// Bild einer Bildkarte (steht auf der Vorderseite).
struct CardImageView: View {
    let imageID: UUID
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(image.size, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
                    .accessibilityLabel("Bild zur Karte")
            } else {
                RoundedRectangle(cornerRadius: DS.Radius.medium).fill(DS.Surface.chip).frame(height: 120)
            }
        }
        .task(id: imageID) {
            image = await ImageStore.shared.loadFromDisk(for: imageID)
        }
    }
}

/// Bild einer Abdeckkarte: der gefragte Bereich ist verdeckt bzw. nach dem Aufdecken markiert.
struct OcclusionImageView: View {
    let imageID: UUID
    let rect: [Double]
    let isRevealed: Bool
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(image.size, contentMode: .fit)
                    .overlay {
                        GeometryReader { geo in
                            let frame = CGRect(x: rect[0] * geo.size.width, y: rect[1] * geo.size.height,
                                               width: rect[2] * geo.size.width, height: rect[3] * geo.size.height)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isRevealed ? Color.clear : DS.Accent.brand)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.Accent.brand, lineWidth: 2))
                                .overlay { if !isRevealed { Text("?").font(.headline).foregroundStyle(.white) } }
                                .frame(width: frame.width, height: frame.height)
                                .position(x: frame.midX, y: frame.midY)
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: DS.Radius.medium).fill(DS.Surface.chip).frame(height: 120)
            }
        }
        .task(id: imageID) {
            image = ImageStore.shared.getImage(for: imageID) ?? NSImage(contentsOf: AppStorageLocation.imageFile(id: imageID))
        }
    }
}

// MARK: - Alle Karten

private struct FlashcardLibraryView: View {
    @ObservedObject var viewModel: ChatViewModel
    var documentSeed: String?
    @State private var scope: Scope = .currentChat
    @State private var search = ""
    @State private var editing: ChatViewModel.DueFlashcard?
    @State private var newFront = ""
    @State private var newBack = ""
    @State private var generateCount = 8
    @State private var isGenerating = false
    @State private var statusText: String?

    enum Scope: String, CaseIterable, Identifiable {
        case currentChat = "Dieser Chat", all = "Alle Chats"
        var id: String { rawValue }
    }

    private var cards: [ChatViewModel.DueFlashcard] {
        let all = viewModel.allFlashcardsWithContext
        let scoped = scope == .all ? all : all.filter { $0.sessionId == viewModel.activeSessionId }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return scoped }
        return scoped.filter { $0.card.front.lowercased().contains(q) || $0.card.back.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                HStack(spacing: DS.Space.xs) {
                    ForEach(Scope.allCases) { item in
                        ChoiceChip(title: item.rawValue, isSelected: scope == item) { scope = item }
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                    TextField("Karten durchsuchen …", text: $search).textFieldStyle(.plain).font(.caption)
                }
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous).fill(DS.Surface.chip))
            }

            if viewModel.activeSession != nil {
                creationBar
            }
            if let statusText {
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }

            if cards.isEmpty {
                Spacer()
                Text(scope == .currentChat ? "Dieser Chat hat noch keine Karten." : "Noch keine Karten.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.s) {
                        ForEach(cards) { item in
                            cardRow(item)
                        }
                    }
                }
            }
        }
        .padding(DS.Space.l)
        .sheet(item: $editing) { item in
            FlashcardEditor(card: item.card) { updated in
                viewModel.updateFlashcard(sessionId: item.sessionId, setId: item.setId, card: updated)
            }
        }
        .onAppear {
            if let documentSeed, !isGenerating { generate(from: documentSeed, title: "Aus Dokument") }
        }
    }

    private var creationBar: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                TextField("Vorderseite (Frage)", text: $newFront)
                    .textFieldStyle(.plain)
                    .modifier(SettingsFieldStyle())
                TextField("Rückseite (Antwort)", text: $newBack)
                    .textFieldStyle(.plain)
                    .modifier(SettingsFieldStyle())
                Button("Anlegen") { addManualCard() }
                    .buttonStyle(SoftActionButtonStyle(tint: DS.Ink.accent))
                    .disabled(newFront.trimmingCharacters(in: .whitespaces).isEmpty || newBack.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack(spacing: DS.Space.s) {
                Text("Aus dem ganzen Chat erzeugen:").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $generateCount) {
                    ForEach([5, 8, 12, 20], id: \.self) { Text("\($0) Karten").tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
                Button {
                    generate(from: nil, title: "Aus dem Chat")
                } label: {
                    if isGenerating { ProgressView().controlSize(.small) } else { Label("Erzeugen", systemImage: "sparkles") }
                }
                .buttonStyle(SoftActionButtonStyle(tint: DS.Ink.accent, prominent: true))
                .disabled(isGenerating)
            }
        }
    }

    private func cardRow(_ item: ChatViewModel.DueFlashcard) -> some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            if let imageID = item.card.imageID, item.card.occlusion == nil {
                CardImageView(imageID: imageID)
                    .frame(width: 56, height: 56)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.card.front).font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(item.card.back).font(.system(size: 12.5, design: .rounded)).foregroundStyle(.secondary)
                HStack(spacing: DS.Space.s) {
                    if scope == .all { Text(item.sessionTitle).lineLimit(1) }
                    Text(dueLabel(item.card))
                    if item.card.imageID != nil {
                        if item.card.occlusion != nil { Label("Abdeckkarte", systemImage: "rectangle.dashed") }
                        else { Label("Bildkarte", systemImage: "photo") }
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
            Button { editing = item } label: { Image(systemName: "pencil") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Bearbeiten").accessibilityLabel("Karte bearbeiten")
            Button { viewModel.deleteFlashcards(sessionId: item.sessionId, setId: item.setId, cardIds: [item.card.id]) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Löschen").accessibilityLabel("Karte löschen")
        }
        .padding(DS.Space.m)
        .background(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous).fill(DS.Surface.chip))
    }

    private func dueLabel(_ card: Flashcard) -> String {
        if card.isNew { return "neu" }
        if card.dueDate <= Date() { return "fällig" }
        return "fällig " + card.dueDate.formatted(.relative(presentation: .named).locale(Locale(identifier: "de_DE")))
    }

    private func addManualCard() {
        guard let sessionId = viewModel.activeSession?.id else { return }
        viewModel.addFlashcards([Flashcard(front: newFront.trimmingCharacters(in: .whitespacesAndNewlines),
                                           back: newBack.trimmingCharacters(in: .whitespacesAndNewlines))],
                                to: sessionId, setTitle: "Eigene Karten")
        newFront = ""
        newBack = ""
        scope = .currentChat
    }

    private func generate(from seed: String?, title: String) {
        guard let session = viewModel.activeSession, !isGenerating else { return }
        isGenerating = true
        statusText = "Erzeuge Karten …"
        let context: String
        if let seed {
            context = String(seed.prefix(12_000))
        } else {
            let dialog = session.messages.filter { $0.role == "user" || $0.role == "assistant" }
            context = ChatViewModel.compactionTranscript(of: dialog, characterBudget: 120_000)
        }
        let count = generateCount
        Task {
            let cards = await viewModel.generateFlashcards(
                instruction: "Erstelle \(count) Karteikarten, die die wichtigsten Inhalte des GESAMTEN Materials abdecken (auch frühe Abschnitte).",
                context: context)?.map(\.card)
            isGenerating = false
            guard let cards else { statusText = "Endpunkt nicht erreichbar – bitte erneut versuchen."; return }
            guard !cards.isEmpty else { statusText = "Die Antwort enthielt keine gültigen Karten – bitte erneut versuchen."; return }
            viewModel.addFlashcards(cards, to: session.id, setTitle: title)
            statusText = "\(cards.count) Karten erzeugt."
            scope = .currentChat
        }
    }
}

private struct FlashcardEditor: View {
    @State var card: Flashcard
    let onSave: (Flashcard) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Karte bearbeiten").font(.headline)
            if let imageID = card.imageID, card.occlusion == nil {
                HStack(alignment: .top, spacing: DS.Space.s) {
                    CardImageView(imageID: imageID).frame(maxHeight: 120)
                    Button("Bild entfernen") { card.imageID = nil }
                        .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.rose))
                }
            }
            Text("Vorderseite").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $card.front).font(.body).frame(height: 70).scrollContentBackground(.hidden)
                .padding(6).background(RoundedRectangle(cornerRadius: DS.Radius.small).fill(DS.Surface.control))
            Text("Rückseite").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $card.back).font(.body).frame(height: 110).scrollContentBackground(.hidden)
                .padding(6).background(RoundedRectangle(cornerRadius: DS.Radius.small).fill(DS.Surface.control))
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sichern") { onSave(card); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(SoftActionButtonStyle(tint: DS.Ink.accent, prominent: true))
            }
        }
        .padding(DS.Space.l)
        .frame(width: 440)
    }
}

// MARK: - Fehlerlog

private struct MistakeLogView: View {
    @ObservedObject var viewModel: ChatViewModel
    let onStartTraining: () -> Void
    @State private var showResolved = false

    private var entries: [MistakeEntry] {
        viewModel.mistakes.filter { showResolved || !$0.isResolved }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                Button {
                    viewModel.startMistakeTraining()
                    onStartTraining()
                } label: {
                    Label("Training aus Fehlern (\(viewModel.openMistakes.count))", systemImage: "figure.strengthtraining.traditional")
                }
                .buttonStyle(SoftActionButtonStyle(tint: DS.Ink.accent, prominent: true))
                .disabled(viewModel.openMistakes.isEmpty)
                .help("Startet einen neuen Chat, der genau diese Fehler mit abgewandelten Quizfragen übt")
                Spacer()
                Toggle("Erledigte zeigen", isOn: $showResolved).toggleStyle(.switch).controlSize(.small).font(.caption)
                Button("Erledigte entfernen") { viewModel.removeResolvedMistakes() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    .disabled(!viewModel.mistakes.contains(where: \.isResolved))
            }
            if entries.isEmpty {
                Spacer()
                VStack(spacing: DS.Space.s) {
                    Image(systemName: "checkmark.circle").font(.system(size: 30, weight: .light)).foregroundStyle(DS.Ink.accent)
                    Text("Keine offenen Fehler").font(.callout).foregroundStyle(.secondary)
                    Text("Falsche Quizantworten und mit „Nochmal“ bewertete Karten landen automatisch hier.")
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.s) {
                        ForEach(entries) { entry in row(entry) }
                    }
                }
            }
        }
        .padding(DS.Space.l)
    }

    private func row(_ entry: MistakeEntry) -> some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: entry.kind == .quiz ? "questionmark.bubble" : "rectangle.on.rectangle.angled")
                .foregroundStyle(entry.isResolved ? Color.secondary : DS.Accent.rose)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.question).font(.system(size: 13, weight: .semibold, design: .rounded))
                if let given = entry.givenAnswer { Text("Deine Antwort: \(given)").font(.caption).foregroundStyle(DS.Accent.rose) }
                if let correct = entry.correctAnswer { Text("Richtig: \(correct)").font(.caption).foregroundStyle(.secondary) }
                HStack(spacing: DS.Space.s) {
                    Text(entry.date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "de_DE"))))
                    if let subject = entry.subject { Text(subject) }
                    if entry.count > 1 { Text("\(entry.count)×") }
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
            .strikethrough(entry.isResolved)
            .textSelection(.enabled)
            Spacer(minLength: 0)
            Button { viewModel.setMistakeResolved(entry.id, resolved: !entry.isResolved) } label: {
                Image(systemName: entry.isResolved ? "arrow.uturn.backward" : "checkmark")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help(entry.isResolved ? "Wieder öffnen" : "Als erledigt markieren")
            .accessibilityLabel(entry.isResolved ? "Wieder öffnen" : "Als erledigt markieren")
            Button { viewModel.deleteMistake(entry.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Löschen").accessibilityLabel("Eintrag löschen")
        }
        .padding(DS.Space.m)
        .background(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous).fill(DS.Surface.chip))
        .opacity(entry.isResolved ? 0.6 : 1)
    }
}
