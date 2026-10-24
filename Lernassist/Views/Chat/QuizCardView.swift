import SwiftUI

/// Interaktive Abfragekarte (Tool `quiz_card`). Multiple Choice oder Freitext; nach der Antwort
/// zeigt die Karte richtig/falsch (falls das Modell die Lösung mitgegeben hat) und die Erklärung.
/// Die Antwort geht als normale Nachricht an das Modell, das dann Feedback gibt.
struct QuizCardView: View {
    let card: QuizCard
    let onAnswer: (_ optionIndex: Int?, _ freeText: String?) -> Void
    /// Nach der Antwort: Frage als Karteikarte merken (nil = Knopf ausblenden).
    var onRemember: (() -> Void)? = nil
    @State private var remembered = false

    @State private var freeText = ""
    @State private var showHint = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Label(L("Abfrage"), systemImage: "questionmark.bubble")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DS.Ink.accent)

            // Frage, Hinweis und Erklärung über den Chat-Renderer: Markdown, Formeln (KaTeX), Tabellen.
            MarkdownView(markdown: card.question)

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
                    MarkdownView(markdown: hint, fontScale: 0.92)
                } else {
                    Button(L("Hinweis anzeigen")) { withAnimation { showHint = true } }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }

            if card.isAnswered, let explanation = card.explanation {
                MarkdownView(markdown: explanation, fontScale: 0.92)
                    .transition(.opacity)
            }

            if card.isAnswered, let onRemember {
                Button {
                    onRemember()
                    withAnimation(.snappy) { remembered = true }
                } label: {
                    Label(remembered ? L("Als Karte gemerkt") : L("Als Karte merken"),
                          systemImage: remembered ? "checkmark" : "rectangle.on.rectangle.angled")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(DS.Ink.accent)
                .disabled(remembered)
            }
        }
        .padding(DS.Space.l)
        .frame(maxWidth: 560, alignment: .leading)
        .glassSurface(cornerRadius: DS.Radius.pill, elevated: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Abfrage: \(card.question)"))
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
                // In Antwort-Knöpfen kein Web-Renderer (würde die Klicks schlucken): Inline-Markdown
                // nativ, einfache TeX-Ausdrücke als Unicode (siehe QuizText).
                Text(QuizText.inline(card.options[index]))
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
        .accessibilityLabel(L("Antwort \(letter): \(String(QuizText.inline(card.options[index]).characters))"))
    }

    @ViewBuilder
    private var freeTextInput: some View {
        if let answer = card.freeTextAnswer {
            Text(QuizText.inline(answer))
                .padding(DS.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DS.Radius.medium).fill(Color.secondary.opacity(0.08)))
        } else {
            HStack {
                TextField(L("Deine Antwort …"), text: $freeText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(submitFreeText)
                Button(L("Antworten"), action: submitFreeText)
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

/// Inline-Darstellung für Antwortoptionen: Markdown (fett, kursiv, Code) nativ und einfache
/// TeX-Formeln als Unicode, z. B. `$\alpha \cdot x^{2}$` → „α · x²“, `\frac{a}{b}` → „a/b“.
enum QuizText {
    static func inline(_ raw: String) -> AttributedString {
        let text = tex(raw)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ",
        "eta": "η", "theta": "θ", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π",
        "rho": "ρ", "sigma": "σ", "tau": "τ", "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "cdot": "·", "times": "×", "div": "÷", "pm": "±", "mp": "∓", "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥",
        "neq": "≠", "ne": "≠", "approx": "≈", "sim": "∼", "equiv": "≡", "propto": "∝", "infty": "∞", "partial": "∂",
        "nabla": "∇", "sum": "∑", "prod": "∏", "int": "∫", "rightarrow": "→", "to": "→", "leftarrow": "←",
        "Rightarrow": "⇒", "Leftarrow": "⇐", "leftrightarrow": "↔", "Leftrightarrow": "⇔", "rightleftharpoons": "⇌",
        "uparrow": "↑", "downarrow": "↓", "in": "∈", "notin": "∉", "subset": "⊂", "cup": "∪", "cap": "∩",
        "forall": "∀", "exists": "∃", "neg": "¬", "land": "∧", "lor": "∨", "degree": "°", "circ": "°",
        "ldots": "…", "dots": "…", "cdots": "⋯", "quad": " ", "qquad": "  ", "%": "%",
    ]

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "−": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ",
    ]
    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "−": "₋", "=": "₌", "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "o": "ₒ", "x": "ₓ",
        "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "m": "ₘ", "n": "ₙ", "p": "ₚ", "s": "ₛ", "t": "ₜ",
    ]

    /// Ersetzt TeX nur innerhalb von $…$, $$…$$, \(…\) und \[…\] – normaler Text bleibt unberührt.
    static func tex(_ text: String) -> String {
        let pattern = #"\$\$(.+?)\$\$|\$(.+?)\$|\\\((.+?)\\\)|\\\[(.+?)\\\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let body = (1...4).compactMap { i -> String? in
                let r = match.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }.first ?? ""
            result += math(body)
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// Wandelt einen TeX-Ausdruck in lesbaren Unicode-Text.
    static func math(_ expression: String) -> String {
        var s = expression
        // \frac{a}{b} → a/b (Klammern nur, wenn nötig), \sqrt{x} → √x
        let group = #"\{([^{}]*)\}"#
        while let range = s.range(of: #"\\[dt]?frac"# + group + group, options: .regularExpression) {
            let parts = matches(in: String(s[range]), group)
            let wrap = { (v: String) in v.count > 1 && v.contains(where: { "+-−·× ".contains($0) }) ? "(\(v))" : v }
            s.replaceSubrange(range, with: parts.count == 2 ? wrap(parts[0]) + "/" + wrap(parts[1]) : "")
        }
        while let range = s.range(of: #"\\sqrt"# + group, options: .regularExpression) {
            let inner = matches(in: String(s[range]), group).first ?? ""
            s.replaceSubrange(range, with: inner.count > 1 ? "√(\(inner))" : "√" + inner)
        }
        // \text{…}, \mathrm{…} usw. → Inhalt
        s = s.replacingOccurrences(of: #"\\(?:text|mathrm|mathbf|mathit|operatorname|textbf|textit|mathsf)\{([^{}]*)\}"#,
                                   with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\(?:left|right|displaystyle|limits)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\[,;:! ]"#, with: " ", options: .regularExpression)
        // Befehle → Symbole (längste zuerst, damit \leq nicht als \le endet)
        for name in symbols.keys.sorted(by: { $0.count > $1.count }) {
            s = s.replacingOccurrences(of: #"\\"# + NSRegularExpression.escapedPattern(for: name) + #"(?![A-Za-z])"#,
                                       with: symbols[name]!, options: .regularExpression)
        }
        // Hoch- und Tiefstellungen
        s = scripts(in: s, marker: "^", map: superscripts, fallback: "^")
        s = scripts(in: s, marker: "_", map: subscripts, fallback: "_")
        s = s.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        return s.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func matches(in text: String, _ pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    /// x^{2} / x^2 → x², c_{0} → c₀; nicht abbildbare Zeichen bleiben als ^(…) bzw. _(…).
    private static func scripts(in text: String, marker: Character, map: [Character: Character], fallback: String) -> String {
        var out = ""
        var chars = Array(text)[...]
        while let c = chars.popFirst() {
            guard c == marker, let next = chars.first else { out.append(c); continue }
            var content = ""
            if next == "{" {
                chars.removeFirst()
                var depth = 1
                while let d = chars.popFirst() {
                    if d == "{" { depth += 1 } else if d == "}" { depth -= 1; if depth == 0 { break } }
                    content.append(d)
                }
            } else {
                content = String(chars.removeFirst())
            }
            if content.allSatisfy({ map[$0] != nil }) {
                out += String(content.map { map[$0]! })
            } else {
                out += fallback + (content.count > 1 ? "(\(content))" : content)
            }
        }
        return out
    }
}

