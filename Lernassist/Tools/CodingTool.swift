import Foundation

// MARK: - CodingTool

final class CodingTool: AppTool {
    let name = "coding_sandbox"
    let displayName = "Coding & Interactive Sandbox"
    let description = """
Führt Code (Python, HTML, JS) in einer sicheren Umgebung aus.
Nutze dieses Tool, um:
- Datenverarbeitung, Logik, Berechnungen und Funktionstests in Python auszuführen.
- Mathematische Diagramme/Plots in Python zu erstellen (z.B. matplotlib). Speichere Bilder IMMER als '.png'.
- Interaktive Animationen, 3D-Szenen (z.B. Three.js), Spiele oder GUIs IMMER als HTML/JS/CSS zu rendern.

WICHTIG:
- Setze `language` auf "python" für Logik, Datenanalyse, Tests und statische Plots. Generierte Bilder werden automatisch angezeigt. Versuche NIEMALS, native interaktive Python-Fenster (wie Pygame, Tkinter, OpenGL) zu öffnen! Diese werden in der sicheren Sandbox blockiert und frieren den Chat ein.
- Setze `language` auf "html" für interaktive Web-Snippets (HTML, CSS, JS, Canvas, WebGL, Three.js). Diese werden direkt im Chat hardwarebeschleunigt und interaktiv gerendert! Nutze HTML/JS für JEDE interaktive visuelle Anforderung.
- HTML-Ausgaben müssen selbstständig sein: Verwende inline-JavaScript/CSS, SVG oder Canvas. Externe `<script src="https://...">`-, `<link href="https://...">`- und ähnliche Ressourcen werden aus Sicherheitsgründen blockiert.
- Das Python-Environment ist app-weit und wird nicht pro Chat neu aufgebaut. Nur die versionierten Skripte/Ergebnisse liegen im jeweiligen temporären Sitzungsordner.
- Jede Python-Ausführung wird als `script_v1.py`, `script_v2.py` usw. im temporären Sitzungsordner gespeichert. Bei einem Fehler bekommst du Exit-Code und Traceback zurück: Lies bei Bedarf zuerst mit `run_command` die tatsächliche Version und sende danach eine korrigierte Vollversion an dieses Tool.
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
    
    // Default ist aus, da Python ausgeführt wird. Muss in den Settings aktiviert werden.
    var isEnabled: Bool = false

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
            let result = try await CodingEnvironment.shared.runPythonScript(code: code, sessionID: sessionID)

            var finalOutput = ""
            if !setupLog.isEmpty {
                finalOutput += "--- PIP INSTALL LOG ---\n\(setupLog)\n\n"
            }
            finalOutput += "--- DATEI ---\nscript_v\(result.scriptVersion).py\n"
            finalOutput += "Gespeicherter Pfad: \(result.scriptPath)\n"
            finalOutput += "--- AUSGABE ---\n"
            finalOutput += result.output.isEmpty ? "(Keine Konsolenausgabe)" : result.output

            if result.timedOut {
                finalOutput += "\n\nExit Code: \(result.exitCode)"
                finalOutput += "\nDas Skript wurde wegen des Zeitlimits beendet. Lies die gespeicherte Datei mit run_command und korrigiere insbesondere Endlosschleifen oder blockierende GUI-Aufrufe."
            } else if result.exitCode != 0 {
                finalOutput += "\n\nExit Code: \(result.exitCode)"
                finalOutput += "\nDas Skript ist mit einem Fehler beendet worden. Nutze run_command (z.B. `head`/`grep`/`cat`) für die tatsächliche script_v\(result.scriptVersion).py und sende danach eine korrigierte Vollversion an coding_sandbox."
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
