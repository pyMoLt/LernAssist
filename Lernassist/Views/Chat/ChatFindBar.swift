import SwiftUI

/// Suche im Chat (⌘F): springt von Treffer zu Treffer (Nachricht bzw. Antwort-Gruppe).
struct ChatFindBar: View {
    @Binding var query: String
    let matches: [UUID]
    @Binding var current: Int
    let onJump: (UUID) -> Void
    let onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(L("Im Chat suchen"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .rounded))
                .frame(width: 200)
                .focused($focused)
                .onSubmit { step(1) }
            Text(query.isEmpty ? "" : (matches.isEmpty ? L("Keine Treffer") : L("\(current + 1) von \(matches.count)")))
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain)
                .disabled(matches.isEmpty)
                .help(L("Vorheriger Treffer"))
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
                .disabled(matches.isEmpty)
                .help(L("Nächster Treffer (Return)"))
            Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .help(L("Suche schließen (Esc)"))
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, 7)
        .glassSurface(Capsule(), elevated: true)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in
            current = 0
            if let first = matches.first { onJump(first) }
        }
    }

    private func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        current = (current + delta + matches.count) % matches.count
        onJump(matches[current])
    }

    /// Zeilen (Nachricht oder Antwort-Gruppe), deren Text den Suchbegriff enthält.
    static func matches(for query: String, in items: [ChatRowItem]) -> [UUID] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else { return [] }
        return items.filter { item in
            let messages: [ChatMessage]
            switch item {
            case .single(let message): messages = [message]
            case .turn(let turn): messages = turn
            }
            return messages.contains { ($0.displayText ?? $0.content).localizedCaseInsensitiveContains(needle) }
        }.map(\.id)
    }
}
