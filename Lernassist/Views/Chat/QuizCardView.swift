import SwiftUI

/// Interaktive Abfragekarte (Tool `quiz_card`). Multiple Choice oder Freitext; nach der Antwort
/// zeigt die Karte richtig/falsch (falls das Modell die Lösung mitgegeben hat) und die Erklärung.
/// Die Antwort geht als normale Nachricht an das Modell, das dann Feedback gibt.
struct QuizCardView: View {
    let card: QuizCard
    let onAnswer: (_ optionIndex: Int?, _ freeText: String?) -> Void

    @State private var freeText = ""
    @State private var showHint = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Label("Abfrage", systemImage: "questionmark.bubble")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DS.Ink.accent)

            Text(card.question)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)

            if card.options.isEmpty {
                freeTextInput
            } else {
                VStack(spacing: DS.Space.s) {
                    ForEach(card.options.indices, id: \.self) { index in
                        optionButton(index)
                    }
                }
            }

            if let hint = card.hint, !card.isAnswered {
                if showHint {
                    Text(hint).font(.callout).foregroundStyle(.secondary)
                } else {
                    Button("Hinweis anzeigen") { withAnimation { showHint = true } }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }

            if card.isAnswered, let explanation = card.explanation {
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .padding(DS.Space.l)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous).strokeBorder(.quaternary))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Abfrage: \(card.question)")
    }

    private func state(of index: Int) -> (symbol: String, tint: Color)? {
        guard let selected = card.selectedIndex else { return nil }
        if let correct = card.correctIndex {
            if index == correct { return ("checkmark.circle.fill", .green) }
            if index == selected { return ("xmark.circle.fill", .red) }
            return nil
        }
        return index == selected ? ("circle.inset.filled", DS.Ink.accent) : nil
    }

    private func optionButton(_ index: Int) -> some View {
        let letter = String(UnicodeScalar(65 + index).map(Character.init) ?? "?")
        let marker = state(of: index)
        return Button {
            onAnswer(index, nil)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text(letter)
                    .font(.callout.weight(.semibold).monospaced())
                    .foregroundStyle(.secondary)
                Text(card.options[index])
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let marker {
                    Image(systemName: marker.symbol).foregroundStyle(marker.tint)
                }
            }
            .padding(.vertical, DS.Space.s)
            .padding(.horizontal, DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                .fill(marker?.tint.opacity(0.12) ?? Color.secondary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(card.isAnswered)
        .accessibilityLabel("Antwort \(letter): \(card.options[index])")
    }

    @ViewBuilder
    private var freeTextInput: some View {
        if let answer = card.freeTextAnswer {
            Text(answer)
                .padding(DS.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DS.Radius.medium).fill(Color.secondary.opacity(0.08)))
        } else {
            HStack {
                TextField("Deine Antwort …", text: $freeText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(submitFreeText)
                Button("Antworten", action: submitFreeText)
                    .buttonStyle(.borderedProminent)
                    .disabled(freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func submitFreeText() {
        let text = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onAnswer(nil, text)
    }
}
