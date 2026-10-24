import SwiftUI

/// Ein Tool-Aufruf im Chat – wie bei einem KI-Agenten: kompakte Zeile mit Symbol, Titel und Status,
/// aufklappbar für Details. coding_sandbox zeigt einen Editor (Code wächst live beim Generieren)
/// und ein Terminal mit der Ausgabe; web_search die gefundenen Quellen.
struct ToolActivityView: View {
    let call: ToolCallInfo
    @State private var isExpanded: Bool
    @State private var userToggled = false

    init(call: ToolCallInfo) {
        self.call = call
        // Eingeklappt, auch während der Code geschrieben wird (Version 4): Live-Code bei jedem
        // Token zu zeichnen kostete viel Leistung. Aufklappen zeigt ihn weiterhin live.
        _isExpanded = State(initialValue: false)
    }

    private var presentation: ToolCallPresentation { ToolCallPresentation(call: call) }

    var body: some View {
        let p = presentation
        VStack(alignment: .leading, spacing: DS.Space.s) {
            header(p)
                .zIndex(1)
            if isExpanded {
                details(p)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .onChange(of: call.result != nil) { _, finished in
            // Nach Abschluss automatisch einklappen, solange der Nutzer nicht selbst geklickt hat.
            if finished, !userToggled, call.name == "coding_sandbox" {
                withAnimation(.snappy) { isExpanded = false }
            }
        }
    }

    private func header(_ p: ToolCallPresentation) -> some View {
        Button {
            userToggled = true
            withAnimation(.snappy) { isExpanded.toggle() }
        } label: {
            HStack(spacing: DS.Space.s) {
                Image(systemName: p.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(p.isError ? Color.orange : DS.Ink.accent)
                    .frame(width: 16)
                    .symbolEffect(.pulse, isActive: p.isRunning)
                Text(p.title)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !isExpanded, let summary = collapsedSummary(p) {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: DS.Space.s)
                statusIcon(p)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, DS.Space.m)
            .background(Capsule().fill(DS.Surface.chip))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(p.title), \(p.isRunning ? L("läuft") : (p.isError ? "fehlgeschlagen" : "fertig"))")
        .accessibilityHint(isExpanded ? L("Details einklappen") : L("Details anzeigen"))
    }

    @ViewBuilder
    private func statusIcon(_ p: ToolCallPresentation) -> some View {
        if p.isRunning {
            ProgressView().controlSize(.mini)
        } else if p.isLimitReached {
            Image(systemName: "info.circle.fill").font(.caption).foregroundStyle(.secondary)
        } else if p.isError {
            Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                .symbolEffect(.bounce, value: p.isError)
        } else if p.hasScriptWarning {
            Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                .help(L("Die Ausgabe wurde angezeigt; beim Probelauf meldete das Skript Fehler (an das Modell gemeldet)."))
        } else {
            Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                .transition(.symbolEffect(.drawOn))
        }
    }

    /// Bitte an das Modell, einen fehlgeschlagenen Lauf zu korrigieren (HTML mit Skriptfehler,
    /// Python mit Fehlercode). nil = nichts zu reparieren.
    private func repairRequest(_ p: ToolCallPresentation) -> String? {
        guard !p.isRunning else { return nil }
        if p.hasScriptWarning {
            let errors = p.cleanedResult.replacingOccurrences(of: CodingTool.htmlScriptErrorPrefix, with: "")
                .components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.joined(separator: "\n")
            return "Die interaktive Ausgabe meldet beim Laden Fehler:\n\(errors)\n\nBitte korrigiere sie und sende die vollständige HTML-Datei erneut."
        }
        if let run = p.codeRun, let code = run.exitCode, code != 0 {
            let tail = run.output.components(separatedBy: "\n").suffix(12).joined(separator: "\n")
            return "Der Python-Code ist mit diesem Fehler abgebrochen:\n```\n\(tail)\n```\nBitte korrigiere ihn und führe ihn erneut aus."
        }
        return nil
    }

    private func collapsedSummary(_ p: ToolCallPresentation) -> String? {
        if p.isRunning {
            // Laufender Code: nur die Länge zeigen – der Code selbst erscheint erst aufgeklappt.
            guard call.name == "coding_sandbox", !p.argumentsComplete else { return nil }
            let chars = p.code.count
            guard chars > 0 else { return nil }
            return chars >= 1000 ? L("\(String(format: "%.1f", Double(chars) / 1000))k Zeichen") : L("\(chars) Zeichen")
        }
        if p.isLimitReached { return L("Limit erreicht") }
        switch call.name {
        case "web_search":
            let count = p.sources.count
            return count > 0 ? (count == 1 ? L("1 Quelle") : L("\(count) Quellen")) : nil
        case "calculate":
            return p.cleanedResult.components(separatedBy: "\n").first.map { String($0.prefix(60)) }
        case "coding_sandbox":
            guard let run = p.codeRun else { return nil }
            return run.exitCode == 0 ? L("ausgeführt") : L("Fehler")
        default:
            return nil
        }
    }

    @ViewBuilder
    private func details(_ p: ToolCallPresentation) -> some View {
        switch call.name {
        case "coding_sandbox":
            VStack(alignment: .leading, spacing: 6) {
                CodeRunCard(presentation: p)
                if let request = repairRequest(p) {
                    Button {
                        NotificationCenter.default.post(name: .repairRequested, object: nil, userInfo: ["text": request])
                    } label: {
                        Label(L("Reparieren lassen"), systemImage: "wrench.adjustable")
                    }
                    .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.amber))
                    .controlSize(.small)
                    .help(L("Das Modell bekommt die Fehlermeldung und schickt eine korrigierte Fassung"))
                }
            }
        case "web_search":
            VStack(alignment: .leading, spacing: 6) {
                SourceList(presentation: p)
                if let statuses = call.researchStatus, !statuses.isEmpty {
                    SourceStatusLine(statuses: statuses)
                }
                if let phases = call.researchPhases, !phases.isEmpty {
                    Text(SourceStatusLine.describe(phases: phases))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .help(L("Dauer der einzelnen Schritte dieser Suche"))
                }
            }
        default:
            if !p.cleanedResult.isEmpty {
                ScrollView {
                    Text(p.cleanedResult)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Space.s)
                }
                .frame(maxHeight: 220)
                .background(RoundedRectangle(cornerRadius: DS.Radius.medium).fill(DS.Surface.chip))
            }
        }
    }
}

// MARK: - Code + Terminal (VS-Code-Look)

struct CodeRunCard: View {
    let presentation: ToolCallPresentation
    @State private var showCode = true

    var body: some View {
        let p = presentation
        let fileName = p.language == "html" ? "simulation.html" : "script.py"
        VStack(alignment: .leading, spacing: 0) {
            // Titelleiste wie ein Editor-Tab
            HStack(spacing: 6) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color.opacity(0.75)).frame(width: 9, height: 9)
                }
                Image(systemName: p.language == "html" ? "chevron.left.slash.chevron.right" : "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(CodeHighlighter.Palette.gutter)
                    .padding(.leading, 6)
                Text(fileName)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(CodeHighlighter.Palette.text)
                if !p.packages.isEmpty {
                    Text("+ " + p.packages.joined(separator: ", "))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(CodeHighlighter.Palette.gutter)
                        .lineLimit(1)
                }
                Spacer()
                Button(showCode ? L("Code ausblenden") : L("Code zeigen")) { withAnimation(.snappy) { showCode.toggle() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(CodeHighlighter.Palette.gutter)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(p.code, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(CodeHighlighter.Palette.gutter)
                .help(L("Code kopieren"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(CodeHighlighter.Palette.titleBar)

            if showCode {
                CodeEditorView(code: p.code, language: p.language, isStreaming: p.isRunning && !p.argumentsComplete)
            }

            TerminalView(presentation: p, fileName: fileName)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous).strokeBorder(Color.black.opacity(0.25)))
        .frame(maxWidth: 720, alignment: .leading)
        .environment(\.colorScheme, .dark)
    }
}

/// Code mit Zeilennummern; folgt beim Streamen automatisch dem Ende.
struct CodeEditorView: View {
    let code: String
    let language: String
    let isStreaming: Bool

    /// Zeilenhöhe von 11,5-pt-Monospace (für die inhaltsabhängige Höhe).
    private static let lineHeight: CGFloat = 14.2

    var body: some View {
        let lines = max(1, code.components(separatedBy: "\n").count)
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                HStack(alignment: .top, spacing: 12) {
                    Text((1...lines).map(String.init).joined(separator: "\n"))
                        .font(.system(size: 11.5, design: .monospaced))
                        .lineSpacing(0)
                        .foregroundStyle(CodeHighlighter.Palette.gutter)
                        .multilineTextAlignment(.trailing)
                    Text(CodeHighlighter.highlight(code + (isStreaming ? "▍" : ""), language: language))
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                }
                .padding(10)
                Color.clear.frame(height: 1).id("end")
            }
            // Kurzer Code ohne Leerraum, langer Code scrollt (Mausrad geht am Ende an den Chat).
            .frame(height: min(CGFloat(lines) * Self.lineHeight + 22, 300))
            .background(CodeHighlighter.Palette.background)
            .onChange(of: code.count) { _, _ in
                if isStreaming { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }
}

/// Terminal mit Befehl, Status und Ausgabe; Fehlerzeilen rot, betroffene Codezeilen markiert.
struct TerminalView: View {
    let presentation: ToolCallPresentation
    let fileName: String

    var body: some View {
        let p = presentation
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(L("TERMINAL"))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(CodeHighlighter.Palette.gutter)
                Spacer()
                statusLabel(p)
            }
            if p.language == "html" {
                line("$ open \(fileName)", color: CodeHighlighter.Palette.gutter)
                if !p.isRunning {
                    line(p.isError ? p.cleanedResult : "Simulation wird unten im Chat angezeigt.",
                         color: p.isError ? CodeHighlighter.Palette.error : CodeHighlighter.Palette.text)
                }
            } else {
                if !p.packages.isEmpty { line("$ uv pip install " + p.packages.joined(separator: " "), color: CodeHighlighter.Palette.gutter) }
                line("$ python \(fileName)", color: CodeHighlighter.Palette.gutter)
                if p.isRunning {
                    line(p.argumentsComplete ? "läuft …" : "wartet auf den Code …", color: CodeHighlighter.Palette.gutter)
                } else if let run = p.codeRun {
                    outputText(run.output.isEmpty ? "(keine Ausgabe)" : run.output, failed: run.exitCode != 0)
                    if let context = run.errorContext {
                        Text(context)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(CodeHighlighter.Palette.error)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(CodeHighlighter.Palette.error.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodeHighlighter.Palette.terminal)
    }

    private func line(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func outputText(_ text: String, failed: Bool) -> some View {
        let lines = text.components(separatedBy: "\n").count
        return ScrollView {
            Text(Self.colorizedOutput(text, failed: failed))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: min(CGFloat(lines) * 13.8 + 6, 220))
    }

    /// Traceback-/Error-Zeilen rot, Rest normal.
    static func colorizedOutput(_ text: String, failed: Bool) -> AttributedString {
        var result = AttributedString()
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            var piece = AttributedString((i == 0 ? "" : "\n") + line)
            let isError = failed && (line.hasPrefix("Traceback") || line.contains("Error") || line.contains("Exception"))
            piece.foregroundColor = isError ? CodeHighlighter.Palette.error : CodeHighlighter.Palette.text
            result += piece
        }
        return result
    }

    @ViewBuilder
    private func statusLabel(_ p: ToolCallPresentation) -> some View {
        if p.isRunning {
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text(L("läuft")).font(.system(size: 10)) }
                .foregroundStyle(CodeHighlighter.Palette.gutter)
        } else if let run = p.codeRun, run.exitCode == 0 {
            Label("fertig", systemImage: "checkmark").font(.system(size: 10)).foregroundStyle(CodeHighlighter.Palette.success)
        } else {
            Label(L("Fehler"), systemImage: "xmark").font(.system(size: 10)).foregroundStyle(CodeHighlighter.Palette.error)
        }
    }
}

// MARK: - Quellen der Websuche

struct SourceList: View {
    let presentation: ToolCallPresentation

    var body: some View {
        let sources = presentation.sources
        VStack(alignment: .leading, spacing: 4) {
            if presentation.isRunning {
                Text(L("Durchsucht Web, Wikipedia und Fachdatenbanken …"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if sources.isEmpty {
                Text(presentation.cleanedResult.prefix(400))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(sources) { source in
                    Button {
                        if let url = URL(string: source.url) { NSWorkspace.shared.open(url) }
                    } label: {
                        HStack(spacing: DS.Space.s) {
                            Text("W\(source.number.dropFirst())")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(DS.Ink.accent)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(source.title).font(.caption).lineLimit(1)
                                Text(source.domain).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(source.url)
                }
            }
        }
        .padding(DS.Space.s)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.medium).fill(DS.Surface.chip))
    }
}


/// Zeiten und Zustand der Recherche-Quellen in einer Zeile („Wikipedia 3,1 s · Europe PMC pausiert“).
struct SourceStatusLine: View {
    let statuses: [ResearchSourceStatus]

    var body: some View {
        Text(statuses.sorted { ($0.seconds ?? 99) < ($1.seconds ?? 99) }.map(Self.describe).joined(separator: " · "))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .help(L("Antwortzeit und Zustand jeder Quelle bei dieser Suche"))
    }

    nonisolated static func describe(_ status: ResearchSourceStatus) -> String {
        let name = status.source.shortName
        let time = status.seconds.map { String(format: "%.1f s", $0) } ?? ""
        // Ein eigener Such-Server, der schweigt, hat fast immer eine veraltete Adresse.
        let checkAddress = status.source == .searxng ? L(" – Adresse in den Einstellungen prüfen") : ""
        switch status.state {
        case .ok: return L("\(name) \(status.hits) Treffer · \(time)")
        case .empty: return L("\(name) \(time) (keine Treffer)")
        case .failed:
            return status.minutesLeft.map { L("\(name) Fehler – pausiert \($0) min") } ?? L("\(name) Fehler")
        case .unreachable:
            let base = status.minutesLeft.map { L("\(name) nicht erreichbar – pausiert \($0) min") } ?? L("\(name) nicht erreichbar")
            return base + checkAddress
        case .rateLimited: return L("\(name) Anfragegrenze – pausiert \(status.minutesLeft ?? 0) min")
        case .paused: return L("\(name) pausiert (noch \(status.minutesLeft ?? 1) min)")
        case .timeout: return L("\(name) antwortet nicht – übersprungen") + checkAddress
        case .skipped: return L("\(name) nicht abgewartet (genug Treffer)")
        }
    }

    nonisolated static func describe(phases: [ResearchPhaseTiming]) -> String {
        phases.map { timing in
            let time = String(format: "%.1f s", timing.seconds)
            switch timing.phase {
            case .sources: return L("Quellen \(time)")
            case .fullText: return L("Volltext \(time)")
            case .rerank: return L("Reranker \(time)")
            case .images: return L("Bilder \(time)")
            }
        }.joined(separator: " · ")
    }
}
