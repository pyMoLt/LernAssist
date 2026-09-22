import Foundation
import AppKit

/// Ein bewusst kleines Terminal-Interface für die Python-Iteration.
///
/// Das Modell bekommt keinen Shell-String und kann keine beliebigen Programme starten. Jeder
/// Aufruf wird gegen die Allowlist in `CodingEnvironment` geprüft, im Session-Ordner ausgeführt
/// und dem Nutzer vorher in einem sichtbaren Dialog gezeigt.
final class TerminalTool: AppTool {
    let name = "run_command"
    let displayName = "Begrenztes Terminal"
    let description = """
Führt einen einzelnen, begrenzten Terminal-Befehl im temporären Coding-Ordner dieser Sitzung aus.
Nutze dieses Tool vor allem, um deine vorherigen Python-Dateien zu prüfen, z.B. mit:
- `ls` zum Auflisten von `script_v1.py`, `script_v2.py` usw.
- `cat`, `head`, `tail` oder `grep`, um den tatsächlichen Dateiinhalt und einen Traceback zu lesen
- `wc`, `file` oder `find`, um Dateien zu untersuchen
- `python3` darf nur eine vorhandene `.py`-Datei aus diesem Ordner ausführen

WICHTIG:
- `arguments` ist ein Array, niemals ein Shell-String. Pipes, Umleitungen, Backticks, `sudo`,
  Netzwerkprogramme, Löschbefehle und beliebige Programme sind nicht verfügbar.
- Jeder Aufruf wird dem Nutzer einzeln zur Bestätigung angezeigt.
- Nach einem Python-Fehler kannst du zuerst mit `ls`, `head`, `cat` oder `grep` die tatsächlich
  gespeicherte Version lesen und anschließend mit `coding_sandbox` eine korrigierte Vollversion
  erzeugen. Die Dateien heißen `script_v1.py`, `script_v2.py` usw.
"""
    let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "command": [
                "type": "string",
                "enum": ["ls", "cat", "head", "tail", "grep", "wc", "find", "sort", "du", "file", "pwd", "python3"],
                "description": "Freigegebener Befehlsname ohne Pfad."
            ],
            "arguments": [
                "type": "array",
                "items": ["type": "string"],
                "description": "Einzelne Argumente als Array; keine Shell-Syntax."
            ]
        ],
        "required": ["command"]
    ]
    var isEnabled: Bool = false

    func run(arguments: String, sessionID: String?) async -> ToolResult {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = json["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("Fehler: Ungültige Argumente – erwartet wird mindestens {\"command\": \"ls\"}.")
        }

        let commandArguments: [String]
        if let parsed = json["arguments"] as? [String] {
            commandArguments = parsed
        } else if json["arguments"] == nil {
            commandArguments = []
        } else {
            return .failure("Fehler: `arguments` muss ein Array aus Strings sein.")
        }

        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard await requestConfirmation(command: normalized, arguments: commandArguments) else {
            return .failure("Der Terminal-Aufruf wurde vom Nutzer abgelehnt.")
        }

        do {
            let result = try await CodingEnvironment.shared.runCommand(
                command: normalized, arguments: commandArguments, sessionID: sessionID
            )
            let invocation = ([result.command] + result.arguments.map(Self.displayArgument)).joined(separator: " ")
            var output = "$ \(invocation)\nArbeitsordner: \(result.workingDirectory)\n"
            if result.timedOut {
                output += "Der Prozess wurde nach 30 Sekunden beendet.\n"
            }
            output += result.output.isEmpty ? "(Keine Ausgabe)" : result.output

            if result.timedOut || result.exitCode != 0 {
                output += "\n\nExit Code: \(result.exitCode)"
                return .failure(output)
            }
            return ToolResult(content: output)
        } catch is CancellationError {
            return .failure("Der Terminal-Aufruf wurde abgebrochen.")
        } catch {
            return .failure("Terminal-Aufruf fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    private func requestConfirmation(command: String, arguments: [String]) async -> Bool {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "Terminal-Befehl ausführen?"
            let invocation = ([command] + arguments.map(Self.displayArgument)).joined(separator: " ")
            alert.informativeText = "Das Modell möchte diesen begrenzten Befehl im temporären Coding-Ordner ausführen:\n\n\(invocation)\n\nEs wird kein allgemeiner Shell-Zugriff gewährt."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Ausführen")
            alert.addButton(withTitle: "Abbrechen")
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    private static func displayArgument(_ value: String) -> String {
        // Nur für Dialog/UI; die eigentliche Ausführung nutzt weiterhin das ungequotete
        // Argument-Array von Process.
        if value.isEmpty { return "\"\"" }
        let safe = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return safe.rangeOfCharacter(from: .whitespacesAndNewlines) == nil ? safe : "\"\(safe)\""
    }
}
