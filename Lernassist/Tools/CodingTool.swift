import Foundation

// MARK: - CodingTool

final class CodingTool: AppTool {
    let name = "coding_sandbox"
    let displayName = "Coding & Interactive Sandbox"
    let description = """
Führt Code aus und zeigt das Ergebnis direkt im Chat. language "python" (Python 3.12 mit numpy, \
pandas, scipy, sympy, matplotlib, seaborn, statsmodels, networkx, openpyxl): Berechnungen, \
Datenauswertung (angehängte Dateien liegen im Arbeitsordner), Plots (Bilder erscheinen automatisch). \
Fehlt ein Paket, nenne es in `install_packages`. language "html": interaktive Erklärungen, Simulationen und Animationen als EINE \
selbstständige HTML-Datei mit inline JS/CSS, SVG oder Canvas (keine externen Skripte/CDNs). \
Nutze HTML für alles Interaktive, Python für Daten und statische Grafiken. Keine GUI-Fenster \
(tkinter, pygame) und kein Netzwerkzugriff. Bei Fehlern bekommst du Traceback und betroffene \
Codezeilen – sende dann eine korrigierte Vollversion.
"""
    let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "code": [
                "type": "string",
                "description": "Der auszuführende Code (Python oder HTML)."
            ],
            "language": [
                "type": "string",
                "enum": ["python", "html"],
                "description": "Die zu verwendende Sprache (python oder html)."
            ],
            "install_packages": [
                "type": "array",
                "items": ["type": "string"],
                "description": "Optional: Nur für Python. Liste von pip-Paketen (z.B. ['matplotlib']), die VOR der Ausführung installiert werden."
            ]
        ],
        "required": ["code", "language"]
    ]
    
    // Standard an (Nutzer, 12.10.2026): Visualisierungen und Datenauswertung sind ausdrücklich
    // gewünscht. Python läuft in der Sandbox (kein Netz, keine Home-Lesezugriffe).
    var isEnabled: Bool = true

    /// Daten-Anhänge des Chats (CSV, Excel, JSON …), die in den Arbeitsordner kopiert werden.
    var dataFilesProvider: (String?) -> [URL] = { _ in [] }

    /// Wiederkehrende Aufforderung im Tool-Ergebnis: das Modell soll den generierten Code/das
    /// Ergebnis dem Nutzer aktiv erklären, statt die Ausführung stillschweigend zu bestätigen.
    private static let explainReminder =
        "Erkläre dem Nutzer jetzt kurz, was der Code macht und was im Ergebnis (Konsolenausgabe/Bild/HTML) zu sehen ist."


    func run(arguments: String, sessionID: String?) async -> ToolResult {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? String,
              let language = json["language"] as? String else {
            return .failure("Fehler: Ungültige Code-Übergabe oder Sprache fehlt.")
        }
        
        if language.lowercased() == "html" {
            if let externalResource = Self.blockedExternalResource(in: code) {
                return .failure("Die HTML-Ausgabe enthält eine externe Ressource (\(externalResource)). Diese Chat-Ansicht blockiert externe Skripte/Styles/Ressourcen. Verwende eine vollständig selbstständige HTML-Datei mit inline-JavaScript, inline-CSS, SVG oder Canvas.")
            }
            // Wird von ChatViewModel direkt als eigene, sandboxed gerenderte Chat-Nachricht
            // eingefügt (siehe ToolArtifact.html) – nicht mehr als Markdown/iframe-Text, da
            // markdown-it html:false gesetzt hat und rohes HTML dort nur als escapter Text
            // erschien (nie tatsächlich gerendert wurde).
            return ToolResult(
                content: "Interaktive HTML-Ausgabe wurde direkt im Chat angezeigt.\n\n" + Self.explainReminder,
                artifacts: [.html(code)]
            )
        }
        
        var setupLog = ""
        
        // Pakete installieren (Nur für Python)
        if let packages = json["install_packages"] as? [String], !packages.isEmpty {
            setupLog += "Installiere Pakete: \(packages.joined(separator: ", "))\n"
            for pkg in packages {
                do {
                    let log = try await CodingEnvironment.shared.installPackage(pkg)
                    setupLog += log + "\n"
                } catch {
                    setupLog += "Fehler bei pip install \(pkg): \(error)\n"
                }
            }
        }
        
        // Code ausführen
        do {
            let inputFiles = dataFilesProvider(sessionID)
            let result = try await CodingEnvironment.shared.runPythonScript(code: code, sessionID: sessionID, inputFiles: inputFiles)

            var finalOutput = ""
            if !setupLog.isEmpty {
                finalOutput += "--- PIP INSTALL LOG ---\n\(setupLog)\n\n"
            }
            if !inputFiles.isEmpty {
                finalOutput += "--- DATEIEN IM ARBEITSORDNER ---\n" + inputFiles.map(\.lastPathComponent).joined(separator: ", ") + "\n\n"
            }
            finalOutput += "--- AUSGABE (script_v\(result.scriptVersion).py) ---\n"
            finalOutput += result.output.isEmpty ? "(Keine Konsolenausgabe)" : result.output

            if result.timedOut {
                finalOutput += "\n\nExit Code: \(result.exitCode)"
                finalOutput += "\nDas Skript wurde wegen des Zeitlimits beendet – prüfe Endlosschleifen oder blockierende Aufrufe und sende eine korrigierte Vollversion."
            } else if result.exitCode != 0 {
                finalOutput += "\n\nExit Code: \(result.exitCode)"
                if let context = Self.errorContext(output: result.output, code: code) {
                    finalOutput += "\n\n--- BETROFFENE CODEZEILEN ---\n" + context
                }
                finalOutput += "\nKorrigiere den Fehler und sende eine vollständige, korrigierte Version an coding_sandbox."
            }

            // Bilder werden NICHT als Base64 in `content` gepackt (füllt sonst bei jeder
            // Folgeanfrage erneut den Modell-Kontext), sondern als eigene Artefakte direkt im
            // Chat angezeigt. Das Modell bekommt nur eine kurze Erwähnung als Text.
            var artifacts: [ToolArtifact] = []
            for path in result.imagePaths {
                if let imgData = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                    artifacts.append(.image(base64: imgData.base64EncodedString()))
                }
            }
            if !artifacts.isEmpty {
                finalOutput += "\n\n(\(artifacts.count) Bild(er) wurden erzeugt und dem Nutzer direkt im Chat angezeigt.)"
            }
            if result.timedOut || result.exitCode != 0 {
                return ToolResult(content: finalOutput, isError: true, errorKind: .fatal, artifacts: artifacts)
            }
            finalOutput += "\n\n" + Self.explainReminder
            return ToolResult(content: finalOutput, artifacts: artifacts)
        } catch {
            return .failure("Schwerwiegender Fehler bei Ausführung: \(error.localizedDescription). Der Code wurde nicht erfolgreich ausgeführt; prüfe die Argumente und versuche eine korrigierte Version.")
        }
    }

    /// Zeilen rund um die letzte Traceback-Stelle im Skript (Zeilennummern bezogen auf den Code
    /// des Modells, ohne den App-Vorspann). Ersetzt das frühere Nachlesen per run_command.
    static func errorContext(output: String, code: String, radius: Int = 2) -> String? {
        let pattern = #"script_v\d+\.py\", line (\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: output, range: NSRange(output.startIndex..., in: output))
        guard let last = matches.last, let range = Range(last.range(at: 1), in: output),
              let scriptLine = Int(output[range]) else { return nil }
        let codeLines = code.components(separatedBy: "\n")
        let line = scriptLine - CodingEnvironment.preludeLineCount
        guard line >= 1, line <= codeLines.count else { return nil }
        let lower = max(1, line - radius), upper = min(codeLines.count, line + radius)
        return (lower...upper).map { number in
            String(format: "%@%4d | %@", number == line ? "→" : " ", number, codeLines[number - 1])
        }.joined(separator: "\n")
    }

    /// Modellgeneriertes HTML bleibt lokal und deterministisch: Die Chat-Ansicht blockiert
    /// Netzwerkzugriffe per CSP und NavigationDelegate. Frühzeitige Validierung verhindert,
    /// dass ein CDN-abhängiges Artefakt als scheinbar fertige, aber statische Ausgabe erscheint.
    private static func blockedExternalResource(in html: String) -> String? {
        let pattern = #"(?is)<\s*(script|link|img|iframe|video|audio|source)\b[^>]*\b(?:src|href)\s*=\s*[\"']\s*(https?:|//)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[range]).lowercased()
    }
}
