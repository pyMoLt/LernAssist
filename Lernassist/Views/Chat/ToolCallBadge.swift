import SwiftUI

// MARK: - ToolCallBadge

struct ToolCallBadge: View {
    let tool: ToolCallInfo
    @State private var isExpanded: Bool
    
    init(tool: ToolCallInfo) {
        self.tool = tool
        self._isExpanded = State(initialValue: tool.result == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.caption2)
                    
                    Text("Tool: \(tool.name.isEmpty ? "Unbekannt" : tool.name)")
                        .font(.caption)
                        .fontWeight(.medium)
                    
                    Spacer()
                    
                    if tool.result != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.green.opacity(0.8))
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                    
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    // Argumente
                    if !tool.arguments.isEmpty && tool.arguments != "{}" {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("INPUT")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.secondary)
                            
                            if let code = parsedCode {
                                ScrollView {
                                    MarkdownView(markdown: "```\(languageForTool)\n\(code)\n```")
                                }
                                .frame(maxHeight: 300)
                                .background(Color.primary.opacity(0.02))
                                .cornerRadius(6)
                            } else {
                                ScrollView {
                                    Text(tool.arguments)
                                        .font(.system(size: 11, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(6)
                                }
                                .frame(maxHeight: 300)
                                .background(Color.primary.opacity(0.05))
                                .cornerRadius(4)
                            }
                        }
                    }
                    
                    // Ergebnis
                    if let result = tool.result {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("OUTPUT")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.secondary)
                            
                            ScrollView {
                                Text(result)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(6)
                            }
                            .frame(maxHeight: 150)
                            .background(Color.primary.opacity(0.05))
                            .cornerRadius(4)
                        }
                    }
                }
                .padding([.horizontal, .bottom], 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.orange.opacity(0.08))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.2), lineWidth: 0.5)
        )
        .clipped()
        .padding(.vertical, 2)
    }
    
    /// Liest das tatsächliche `"language"`-Argument aus, statt es (falsch) aus dem Tool-Namen zu
    /// raten – `coding_sandbox` enthält weder "javascript" noch "html" im Namen, weshalb die
    /// bisherige Namens-basierte Erkennung immer "python" lieferte, selbst für HTML-Code.
    private var languageForTool: String {
        if let data = tool.arguments.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let lang = obj["language"] as? String {
            return lang.lowercased() == "html" ? "html" : lang
        }
        // Streaming evtl. noch unvollständig – best effort per Substring-Suche.
        if tool.arguments.contains("\"language\"") && tool.arguments.contains("html") { return "html" }
        return "python"
    }

    /// Extrahiert den `"code"`-Wert aus den Tool-Argumenten für die Syntax-hervorgehobene Anzeige.
    /// War vorher komplett tot: der Namens-Check verglich mit "runPythonScript"/"runJavaScript" –
    /// Namen, die es nie gab (das Tool heißt "coding_sandbox") – wodurch dieser Zweig NIE griff und
    /// Input immer als unformatierter JSON-Rohtext angezeigt wurde.
    private var parsedCode: String? {
        guard tool.name == "coding_sandbox" else { return nil }

        // 1. Bevorzugt: vollständiges JSON parsen (korrekt sobald das Argument-Streaming fertig ist).
        if let data = tool.arguments.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = obj["code"] as? String {
            return code
        }

        // 2. Fallback für noch unvollständiges JSON während des Streamings: nicht-gierige Regex
        //    (`.*?` statt `.*`) – die vorherige gierige Variante hätte bei einem vollständigen
        //    JSON-Objekt bis zum LETZTEN " im gesamten Fragment gematcht (z.B. bis ins
        //    nachfolgende "language"-Feld hinein) statt beim Ende des code-Strings zu stoppen.
        let pattern = "\"code\"\\s*:\\s*\"(.*?)(?<!\\\\)\""
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
            let nsrange = NSRange(tool.arguments.startIndex..<tool.arguments.endIndex, in: tool.arguments)
            if let match = regex.firstMatch(in: tool.arguments, options: [], range: nsrange),
               let r = Range(match.range(at: 1), in: tool.arguments) {
                return unescapeJSONString(String(tool.arguments[r]))
            }
        }

        // 3. Noch kein schließendes " vorhanden (Argument wird gerade erst gestreamt) – zeige
        //    trotzdem den bisherigen Stand an, statt einer leeren Fläche bis alles fertig ist.
        if let codeKeyRange = tool.arguments.range(of: "\"code\""),
           let colonRange = tool.arguments.range(of: ":", range: codeKeyRange.upperBound..<tool.arguments.endIndex),
           let openQuoteRange = tool.arguments.range(of: "\"", range: colonRange.upperBound..<tool.arguments.endIndex) {
            let partial = unescapeJSONString(String(tool.arguments[openQuoteRange.upperBound...]))
            return partial.isEmpty ? nil : partial
        }
        return nil
    }

    /// Decodiert die gängigen JSON-String-Escapes. `\uXXXX`-Sequenzen (Audit 2.7) werden
    /// wirklich dekodiert statt als rohe Escape-Sequenz im Code-Block zu landen. (Reine
    /// Surrogat-Hälften aus Emoji-Paaren bleiben unverändert – für die Code-Vorschau
    /// ist das Detail irrelevant.)
    private func unescapeJSONString(_ raw: String) -> String {
        var s = raw
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\t", with: "\t")

        if let regex = try? NSRegularExpression(pattern: "\\\\u([0-9a-fA-F]{4})") {
            var replacements: [(NSRange, String)] = []
            regex.enumerateMatches(in: s, range: NSRange(s.startIndex..., in: s)) { match, _, _ in
                guard let match,
                      let hexRange = Range(match.range(at: 1), in: s),
                      let value = UInt32(s[hexRange], radix: 16),
                      let scalar = Unicode.Scalar(value) else { return }
                replacements.append((match.range, String(Character(scalar))))
            }
            let ns = NSMutableString(string: s)
            // Rückwärts ersetzen, damit die (auf den Originalstring bezogenen) Ranges gültig bleiben.
            for (range, character) in replacements.reversed() {
                ns.replaceCharacters(in: range, with: character)
            }
            s = ns as String
        }

        return s.replacingOccurrences(of: "\\\\", with: "\\")
    }
}
