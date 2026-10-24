import Foundation

// MARK: - CodingTool

final class CodingTool: AppTool {
    let name = "coding_sandbox"
    let displayName = "Coding & Interactive Sandbox"
    let description = """
Führt Code aus und zeigt das Ergebnis direkt im Chat – für Datenauswertung, Berechnungen, Grafiken \
und interaktive Darstellungen. language "python" (Python 3.12 mit numpy, pandas, scipy, sympy, matplotlib, \
seaborn, statsmodels, networkx, openpyxl, requests): Berechnungen, Datenauswertung (angehängte Dateien liegen im \
Arbeitsordner), Plots (speichere Grafiken mit plt.savefig('plot.png') oder plt.show(); du erhältst im Ergebnis eine \
[B#]-Nummer und kannst die Grafik mit [B#] allein in einer Zeile an der passenden Stelle deiner Antwort einbinden). Fehlt ein Paket, nenne es in `install_packages`. \
language "html": interaktive Erklärungen, Simulationen und Animationen als EINE selbstständige HTML-Datei \
mit inline JS/CSS, SVG oder Canvas (keine externen Skripte/CDNs). Keine GUI-Fenster (tkinter, pygame). \
Python darf Daten aus dem Internet laden, nur über https (ganz normal mit requests, urllib oder \
pd.read_csv("https://…")). Neue Domains bestätigt der Nutzer automatisch per Dialog – du musst nichts \
weiter tun. Erlaubt sind Datenformate wie CSV, JSON, Excel und PDF; wird eine Verbindung abgelehnt, steht \
der Grund in der Fehlermeldung (\"LernAssist: …\"). Bei Fehlern bekommst du Traceback und betroffene Codezeilen – sende dann eine \
korrigierte Vollversion.
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
    
    // Standard an (Entscheidung vom 12.10.2026): Visualisierungen und Datenauswertung sind ausdrücklich
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
            return await runHTML(Self.sanitizeHTMLCode(code))
        }
        
        // Ohne eingerichtete Umgebung gibt es nur kryptische Sandbox-Fehler (execvp …). Klar melden,
        // damit das Modell nicht auf Umwege (ASCII-Grafik, HTML) ausweicht und der Nutzer weiß, was zu tun ist.
        let legacyPython = AppStorageLocation.root.appendingPathComponent("venv/bin/python3").path
        guard PythonEnvironmentInstaller.isReady || FileManager.default.isExecutableFile(atPath: legacyPython) else {
            return .failure("Die Python-Umgebung ist auf diesem Mac noch nicht eingerichtet (Einstellungen → Tools → Python-Sandbox → „Neu einrichten“). Führe in dieser Antwort keinen Python-Code aus und sage dem Nutzer kurz, dass die Einrichtung nötig ist.")
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
        
        return await runPython(code: code, sessionID: sessionID, setupLog: setupLog)
    }

    private func runPython(code: String, sessionID: String?, setupLog: String) async -> ToolResult {
        do {
            let inputFiles = dataFilesProvider(sessionID)
            let result = try await CodingEnvironment.shared.runPythonScript(
                code: code, sessionID: sessionID, inputFiles: inputFiles)

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
            } else if result.exitCode == 71, result.output.contains("sandbox-exec") {
                return .failure("Die Python-Sandbox konnte den Interpreter nicht starten (\(result.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))). Das ist ein Problem der App-Umgebung, nicht deines Codes – wiederhole den Aufruf nicht, sondern sage dem Nutzer, dass die Python-Umgebung neu eingerichtet werden sollte (Einstellungen → Tools).")
            } else if result.exitCode != 0 {
                finalOutput += "\n\nExit Code: \(result.exitCode)"
                if let context = Self.errorContext(output: result.output, code: code) {
                    finalOutput += "\n\n--- BETROFFENE CODEZEILEN ---\n" + context
                }
                if !CodingEnvironment.shared.limits.internetEnabled, Self.looksLikeNetworkAttempt(result.output) {
                    finalOutput += "\nInternet für Python ist in den Einstellungen ausgeschaltet. Arbeite ohne Online-Daten oder nutze web_search."
                }
                if result.output.contains("was never closed") || result.output.contains("unexpected EOF")
                    || result.output.contains("expected an indented block") && code.hasSuffix(":") {
                    finalOutput += "\nDer Code wirkt abgeschnitten – sende ihn vollständig."
                }
                finalOutput += "\nKorrigiere den Fehler und sende eine vollständige, korrigierte Version an coding_sandbox."
            }

            // Erzeugte Grafiken werden wie Recherche-Bilder im Bildspeicher der App abgelegt und
            // bekommen eine fortlaufende [B#]-Nummer (in ChatViewModel.renumberImages eindeutig
            // über Websuche, URL-Lesen und Python-Plots hinweg). So kann das Modell sie mit [B#]
            // exakt an der passenden Stelle im Text einbinden, ohne den Prefix-Cache zu belasten.
            var plotRefs: [ResearchImageRef] = []
            for path in result.imagePaths {
                guard let imgData = try? Data(contentsOf: URL(fileURLWithPath: path)), !imgData.isEmpty else { continue }
                let id = UUID()
                try? FileManager.default.createDirectory(at: AppStorageLocation.imagesDir, withIntermediateDirectories: true)
                guard (try? imgData.write(to: AppStorageLocation.imageFile(id: id), options: .atomic)) != nil else { continue }
                let fileName = URL(fileURLWithPath: path).lastPathComponent
                let caption = (fileName == "output_auto_plot.png" || fileName.hasPrefix("output_auto_plot_"))
                    ? "Python-Plot"
                    : fileName
                plotRefs.append(ResearchImageRef(
                    number: plotRefs.count + 1,
                    imageID: id,
                    caption: caption,
                    sourceURL: "lernassist-plot://\(id.uuidString)",
                    pageURL: "",
                    domain: "Python-Plot"
                ))
            }
            let artifacts: [ToolArtifact] = plotRefs.isEmpty ? [] : [.researchImages(plotRefs)]
            if !plotRefs.isEmpty {
                let lines = plotRefs.map { "[B\($0.number)] Erzeugte Grafik (\($0.caption))" }.joined(separator: "\n")
                finalOutput += "\n\nAbbildungen (schreibe [B#] allein in eine Zeile direkt vor oder nach dem Absatz, auf den sich die Grafik bezieht, um sie dort einzubetten):\n" + lines
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

    /// Hat der Code versucht, selbst ins Netz zu gehen (requests, urllib, socket)?
    static func looksLikeNetworkAttempt(_ output: String) -> Bool {
        let markers = ["ConnectionError", "NewConnectionError", "urlopen error", "getaddrinfo", "gaierror",
                       "Max retries exceeded", "Network is unreachable", "nodename nor servname",
                       "socket.error", "Failed to establish a new connection", "PermissionError: [Errno 1]"]
        return markers.contains { output.contains($0) }
    }

    static let htmlScriptErrorPrefix = "Die interaktive HTML-Ausgabe wird angezeigt, das Skript meldet beim Laden aber Fehler:"

    /// HTML-Ausgabe: bekannte Bibliotheken kommen lokal aus der App, andere externe Domains gibt
    /// der Nutzer frei (Einmal / Immer / Ablehnen). Ein kurzer, unsichtbarer Probelauf meldet
    /// Skriptfehler im Tool-Ergebnis – das Modell kann dann eine korrigierte Fassung schicken.
    /// Wird von ChatViewModel als eigene, sandboxed gerenderte Chat-Nachricht eingefügt.
    private func runHTML(_ html: String) async -> ToolResult {
        var html = html
        let rewrite = HTMLLibraries.rewrite(html)
        var allowedHosts: [String] = []
        if !rewrite.unknownHosts.isEmpty {
            let hosts = rewrite.unknownHosts
            guard let granted = await MainActor.run(body: { HTMLLibraryPermissions.shared.requestPermission(hosts: hosts) }) else {
                return .failure("Die HTML-Ausgabe lädt Dateien von \(hosts.joined(separator: ", ")); der Nutzer hat das abgelehnt. Verwende eine vollständig selbstständige HTML-Datei mit inline-JavaScript, inline-CSS, SVG oder Canvas.")
            }
            allowedHosts = granted
        }

        var errors = await HTMLPreflight.errors(in: html, allowedHosts: allowedHosts)
        // Auto-Korrektur: Skripte im <head>, die zu früh auf Elemente zugreifen, ans Ende verschieben.
        if HTMLArtifactRuntime.looksLikeEarlyDOMAccess(errors), let moved = HTMLArtifactRuntime.moveHeadScriptsToBodyEnd(html) {
            let retry = await HTMLPreflight.errors(in: moved, allowedHosts: allowedHosts)
            if retry.count < errors.count {
                html = moved
                errors = retry
            }
        }

        var content = "Interaktive HTML-Ausgabe wurde direkt im Chat angezeigt."
        if !errors.isEmpty {
            content = Self.htmlScriptErrorPrefix + "\n"
                + errors.prefix(5).map { "- " + $0 }.joined(separator: "\n")
                + "\nKorrigiere den Code und sende die vollständige HTML-Datei erneut."
        }
        return ToolResult(content: content + "\n\n" + Self.explainReminder,
                          artifacts: [.html(html, allowedHosts: allowedHosts)])
    }

    /// Bereinigt HTML-Code von Code-Block-Markern (```html ... ```), falls ein Modell
    /// das HTML in Markdown-Fences verpackt hat.
    static func sanitizeHTMLCode(_ rawCode: String) -> String {
        var code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if code.hasPrefix("```") {
            let lines = code.components(separatedBy: "\n")
            if lines.count >= 2 {
                let startIdx = 1
                let endIdx = lines.last?.trimmingCharacters(in: .whitespaces) == "```" ? lines.count - 1 : lines.count
                if startIdx < endIdx {
                    code = lines[startIdx..<endIdx].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return code
    }

    /// Zeilen rund um die letzte Traceback-Stelle im Skript (Zeilennummern bezogen auf den Code
    /// des Modells, ohne den App-Vorspann). Ersetzt das frühere Nachlesen per run_command.
    static func errorContext(output: String, code: String, radius: Int = 2) -> String? {
        let pattern = #"script_v\d+\.py\", line (\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: output, range: NSRange(output.startIndex..., in: output))
        guard let last = matches.last, let range = Range(last.range(at: 1), in: output),
              let scriptLine = Int(output[range]) else { return nil }
        let cleanCode = CodingEnvironment.sanitizePythonCode(code)
        let codeLines = cleanCode.components(separatedBy: "\n")
        let line = scriptLine - CodingEnvironment.preludeLineCount
        guard line >= 1, line <= codeLines.count else { return nil }
        let lower = max(1, line - radius), upper = min(codeLines.count, line + radius)
        return (lower...upper).map { number in
            String(format: "%@%4d | %@", number == line ? "→" : " ", number, codeLines[number - 1])
        }.joined(separator: "\n")
    }

}
