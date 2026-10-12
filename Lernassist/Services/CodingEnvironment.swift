import Foundation
import AppKit
import Darwin
import os

/// Verwaltet das eine app-weite Python Virtual Environment für LernAssist.
/// Es gibt bewusst kein Environment pro Chat: Chats teilen diese Installation; nur ihre
/// versionierten Skripte und kurzlebigen Ergebnisse liegen getrennt in CodingOutput/<session>.
///
/// `nonisolated`, weil das Projekt `-default-isolation=MainActor` nutzt: ohne diese Markierung
/// würde JEDE Methode hier implizit auf den Main-Thread gehievt. Diese Klasse macht ausschließlich
/// blockierendes Prozess-/Datei-I/O (venv-Erstellung, Python-Ausführung, pip install) – lief das
/// je auf dem Main-Actor, fror die komplette App für die Dauer der Ausführung ein (beobachteter Bug:
/// UI reagiert während der Code-Ausführung nicht, Tool-Badge nicht antippbar).
nonisolated final class CodingEnvironment {
    static let shared = CodingEnvironment()

    private let fileManager = FileManager.default

    /// Basisordner in Application Support
    var baseDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("LernAssist")
    }

    /// Aktive Umgebung: die eigene Python-3.12-Umgebung (PythonEnvironmentInstaller), solange
    /// sie noch nicht fertig ist das alte venv aus dem System-Python.
    var venvDirectory: URL {
        PythonEnvironmentInstaller.isReady ? PythonEnvironmentInstaller.venv : baseDirectory.appendingPathComponent("venv")
    }

    /// Pakete ohne Rückfrage installieren (Einstellung; Standard: nachfragen).
    var autoInstallPackages = false

    var outputDirectory: URL {
        baseDirectory.appendingPathComponent("CodingOutput")
    }

    var pythonPath: String {
        venvDirectory.appendingPathComponent("bin").appendingPathComponent("python3").path
    }

    var pipPath: String {
        venvDirectory.appendingPathComponent("bin").appendingPathComponent("pip3").path
    }

    private init() {}

    /// Initialisiert das Environment (erstellt Ordner und venv falls nötig).
    /// Bewusst `async` statt `waitUntilExit()` — wird per `Task.detached` beim App-Start
    /// angestoßen und darf dabei niemals die UI blockieren (venv-Erstellung kann Sekunden dauern).
    func setupEnvironmentIfNeeded(onStatus: @escaping @Sendable (PythonEnvironmentStatus) -> Void = { _ in }) async {
        do {
            if !fileManager.fileExists(atPath: outputDirectory.path) {
                try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            }
        } catch {
            AppLog.services.error("CodingOutput konnte nicht angelegt werden: \(error.localizedDescription)")
        }
        await PythonEnvironmentInstaller.shared.ensureInstalled(onStatus: onStatus)
    }

    /// Ergebnis eines Python-Laufs (Nutzer-Feature Python-Iteration): rohe Bestandteile für
    /// das Modell-Feedback. Die modellgerichtete Formatierung (Exit-Code, Traceback, Iterations-
    /// hinweis, Pfad) macht der CodingTool.
    struct PythonRunResult {
        let output: String
        let imagePaths: [String]
        let exitCode: Int32
        let timedOut: Bool
        /// Absoluter Pfad der geschriebenen Skript-Version (z.B. .../CodingOutput/<session>/script_v3.py).
        let scriptPath: String
        let scriptVersion: Int
    }

    /// Ergebnis eines ausdrücklich bestätigten, begrenzten Terminal-Aufrufs.
    struct CommandRunResult {
        let output: String
        let exitCode: Int32
        let timedOut: Bool
        let command: String
        let arguments: [String]
        let workingDirectory: String
    }

    /// Max. gespeicherte Skript-Versionen pro Session-Ordner (Nutzer-Feature): Cap gegen
    /// endloses Anwachsen; die ältesten Versionen fliegen zuerst raus.
    private static let maxScriptVersions = 10
    /// Ausgabe-Kappung (Nutzer-Feature): Volle stdout/stderr inkl. Traceback statt aggressivem
    /// Trimmen, aber mit Cap gegen Kontext-Flut. Das ENDE bleibt erhalten – Tracebacks und
    /// Fehlermeldungen stehen typischerweise am Ende der Ausgabe.
    private static let maxOutputCharacters = 10_000

    /// Führt ein Python-Skript aus und gibt stdout/stderr, Exit-Code sowie generierte
    /// Bild-Dateien zurück. Das Skript wird VERSIONIERT abgelegt (script_v1.py, script_v2.py,
    /// ...) – so kann das Modell seine eigenen früheren Versionen über das Terminal-Tool
    /// (cat/grep/head) erneut lesen und iterativ überarbeiten, statt aus dem Gedächtnis neu
    /// zu schreiben. Vorher wurde pro Run immer dieselbe script.py überschrieben.
    func runPythonScript(code: String, sessionID: String?, inputFiles: [URL] = []) async throws -> PythonRunResult {
        let chatID = Self.safeSessionID(sessionID)
        let chatOutputDirectory = outputDirectory.appendingPathComponent(chatID)

        if !fileManager.fileExists(atPath: chatOutputDirectory.path) {
            try fileManager.createDirectory(at: chatOutputDirectory, withIntermediateDirectories: true, attributes: nil)
        }

        // Aufräumen vor jedem Run: alte generierte Artefakte (PNGs etc.) entfernen, damit sie
        // nicht bei jedem Folgelauf erneut als "neu generiert" erkannt würden – aber die
        // versionierten Skripte und das Sandbox-Profil bleiben bewusst liegen (Nutzer-Feature
        // Python-Iteration). Vorher wurde der komplette Ordner geleert; das überschrieb außerdem
        // jede Skript-Version (Audit N23), was die Datei-Kollisionen paralleler Calls maskierte.
        if let files = try? fileManager.contentsOfDirectory(atPath: chatOutputDirectory.path) {
            for file in files where !(file.hasSuffix(".py") || file == "sandbox.sb") {
                try? fileManager.removeItem(at: chatOutputDirectory.appendingPathComponent(file))
            }
        }

        // Daten-Anhänge des Chats (CSV, Excel, JSON …) in den Arbeitsordner kopieren: Die Sandbox
        // darf außerhalb dieses Ordners im Home nichts lesen (Phase 0, Lese-Sperre).
        var copiedInputNames: Set<String> = []
        for file in inputFiles {
            let target = chatOutputDirectory.appendingPathComponent(file.lastPathComponent)
            try? fileManager.removeItem(at: target)
            if (try? fileManager.copyItem(at: file, to: target)) != nil {
                copiedInputNames.insert(file.lastPathComponent)
            }
        }

        let nextScript = nextScriptURL(in: chatOutputDirectory)
        let scriptURL = nextScript.url
        // Erzwingt einen Headless-Matplotlib-Backend und überschreibt plt.show()
        // automatisch mit plt.savefig(), damit die KI keinen Fehler bekommt, wenn sie plt.show() aufruft.
        // Wenn das Skript aber schon selbst plt.savefig() genutzt hat, wird plt.show() ignoriert,
        // um doppelte Bilder in der Ausgabe zu vermeiden.
        let guardedCode = Self.pythonPrelude + "\n" + code
        try guardedCode.write(to: scriptURL, atomically: true, encoding: .utf8)

        // Sandbox-Profil mit gezielter Read-Denylist und Exec-Allowlist schreiben. Das Profil
        // wird auch vom run_command-Tool verwendet; dadurch gelten für Modell-Code und bestätigte
        // Terminal-Aufrufe dieselben Grenzen.
        let profileURL = try writeSandboxProfile(for: chatOutputDirectory)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-f", profileURL.path, pythonPath, scriptURL.path]
        process.currentDirectoryURL = chatOutputDirectory
        
        // Minimal-Environment statt vollständiger Vererbung (Audit T4/C5): Das LLM-generierte
        // Skript könnte sonst die App-Umgebung (inkl. evtl. API-Keys) über `os.environ` lesen und
        // per stdout exfiltrieren. Nur was Python/Server-Bibliotheken nachweislich brauchen.
        let env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": chatOutputDirectory.path,
            "TMPDIR": NSTemporaryDirectory(),
            "MPLCONFIGDIR": chatOutputDirectory.path,
            "XDG_CACHE_HOME": chatOutputDirectory.path, // Verhindert Fontconfig Cache Errors
        ]
        process.environment = env

        // 150s: großzügig genug für normale Datenanalyse/Plots, verhindert aber ein für immer
        // hängendes Skript (z.B. eine Endlosschleife oder eine geblockte native Fensterschleife,
        // siehe Warnung in CodingTool.description) davon, den kompletten Chat einzufrieren – ohne
        // Timeout wartete runProcess vorher unbegrenzt auf die Prozess-Beendigung, wodurch weder
        // eine Antwort noch neue Nachrichten im selben Chat je wieder ankamen.
        let result = try await runProcess(process, timeout: 150)
        var output = result.output
        if result.timedOut {
            output += "\n\n[Skript nach 150s abgebrochen – vermutlich eine Endlosschleife oder ein blockierender Aufruf (z.B. ein natives GUI-Fenster).]"
        } else if output.isEmpty && result.exitCode != 0 {
            output = "Exit Code: \(result.exitCode)"
        }

        // Suche nach generierten Bildern
        var imagePaths: [String] = []
        if let files = try? fileManager.contentsOfDirectory(atPath: chatOutputDirectory.path) {
            for file in files {
                if (file.hasSuffix(".png") || file.hasSuffix(".jpg") || file.hasSuffix(".jpeg")) && !copiedInputNames.contains(file) {
                    imagePaths.append(chatOutputDirectory.appendingPathComponent(file).path)
                }
            }
        }

        return PythonRunResult(
            output: Self.cappedOutput(output.trimmingCharacters(in: .whitespacesAndNewlines)),
            imagePaths: imagePaths.sorted(),
            exitCode: result.exitCode,
            timedOut: result.timedOut,
            scriptPath: scriptURL.path,
            scriptVersion: nextScript.version
        )
    }

    /// Vorspann jedes Skripts: Headless-Matplotlib, plt.show() → PNG. 150 dpi statt 300: Die
    /// Bilder gehen remote über Tailscale und als Base64 in den Chat – 300 dpi bei 12×8 Zoll
    /// ergaben 3600×2400 px (mehrere MB) ohne sichtbaren Gewinn im Chat.
    static let pythonPrelude = """
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        import glob
        plt.rcParams['figure.dpi'] = 150
        plt.rcParams['figure.figsize'] = (10, 6)
        plt.rcParams['font.size'] = 12
        def custom_show(*args, **kwargs):
            if not (glob.glob('*.png') + glob.glob('*.jpg') + glob.glob('*.jpeg')):
                plt.savefig('output_auto_plot.png', bbox_inches='tight')
        plt.show = custom_show
    except ImportError:
        pass
    """

    /// Zeilen vor dem Nutzer-Code im Skript (für Traceback-Zeilennummern).
    static var preludeLineCount: Int { pythonPrelude.components(separatedBy: "\n").count }

    // MARK: - Begrenztes Terminal

    /// Führt einen einzelnen, ausdrücklich bestätigten Read-only-/Analyse-Aufruf aus.
    /// Es gibt keinen Shell-String: Der Befehl und jedes Argument werden separat an Process
    /// übergeben. Der aktuelle Session-Ordner ist das Arbeitsverzeichnis; Pfadargumente dürfen
    /// diesen Ordner nicht verlassen.
    func runCommand(command: String, arguments: [String], sessionID: String?) async throws -> CommandRunResult {
        try Task.checkCancellation()

        let normalizedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let executable = terminalExecutable(for: normalizedCommand) else {
            throw Self.commandError("Der Befehl '\(command)' ist nicht freigegeben.")
        }

        let chatID = Self.safeSessionID(sessionID)
        let chatOutputDirectory = outputDirectory.appendingPathComponent(chatID)
        if !fileManager.fileExists(atPath: chatOutputDirectory.path) {
            try fileManager.createDirectory(at: chatOutputDirectory, withIntermediateDirectories: true, attributes: nil)
        }
        let validatedArguments = try Self.validateTerminalArguments(
            arguments, command: normalizedCommand, within: chatOutputDirectory
        )

        let profileURL = try writeSandboxProfile(for: chatOutputDirectory)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-f", profileURL.path, executable] + validatedArguments
        process.currentDirectoryURL = chatOutputDirectory
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": chatOutputDirectory.path,
            "TMPDIR": NSTemporaryDirectory(),
            "MPLCONFIGDIR": chatOutputDirectory.path,
            "XDG_CACHE_HOME": chatOutputDirectory.path,
        ]

        let result = try await runProcess(process, timeout: 30)
        return CommandRunResult(
            output: Self.cappedOutput(result.output.trimmingCharacters(in: .whitespacesAndNewlines)),
            exitCode: result.exitCode,
            timedOut: result.timedOut,
            command: normalizedCommand,
            arguments: validatedArguments,
            workingDirectory: chatOutputDirectory.path
        )
    }

    /// Ermittelt die nächste stabile Skriptversion und entfernt nur die ältesten Versionen,
    /// sobald das Session-Limit erreicht ist. Andere Dateien (z.B. vom Nutzer importierte CSVs)
    /// werden nicht angefasst.
    private func nextScriptURL(in directory: URL) -> (url: URL, version: Int) {
        let versionPattern = try? NSRegularExpression(pattern: "^script_v([0-9]+)\\.py$")
        let existing: [(version: Int, url: URL)] = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ))?.compactMap { url in
            let name = url.lastPathComponent
            guard let regex = versionPattern,
                  let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let range = Range(match.range(at: 1), in: name),
                  let version = Int(name[range]) else { return nil }
            return (version, url)
        } ?? []

        if existing.count >= Self.maxScriptVersions {
            let numberToRemove = existing.count - Self.maxScriptVersions + 1
            for old in existing.sorted(by: { $0.version < $1.version }).prefix(numberToRemove) {
                try? fileManager.removeItem(at: old.url)
            }
        }

        let nextVersion = (existing.map(\.version).max() ?? 0) + 1
        return (
            directory.appendingPathComponent("script_v\(nextVersion).py"),
            nextVersion
        )
    }

    /// Erzeugt das gemeinsam verwendete Sandbox-Profil.
    ///
    /// Eine pauschale `(deny file-read*)`-Allowlist ist auf macOS 27 für Prozessstarts nicht
    /// zuverlässig: dyld/Framework-Ladevorgänge brechen bereits vor dem Python-Entry-Point ab.
    /// Deshalb werden sensible Pfade gezielt gesperrt, während Prozessstarts strikt auf die
    /// freigegebenen Interpreter/Coreutils begrenzt bleiben.
    private func writeSandboxProfile(for outputDirectory: URL) throws -> URL {
        let profileURL = outputDirectory.appendingPathComponent("sandbox.sb")
        var profileLines: [String] = [
            "(version 1)",
            "(allow default)",
            "(deny network*)",
            "(deny file-write*)",
            "(allow file-write* (subpath \"/private/tmp\"))",
            "(allow file-write* (subpath \"/private/var/folders\"))",
            "(allow file-write* (subpath \"/dev\"))",
            "(allow file-write* (subpath \"\(outputDirectory.path)\"))",
            "(deny process-exec*)",
            "(allow process-exec* (subpath \"\(venvDirectory.path)\"))",
        ]

        let resolvedPython = URL(fileURLWithPath: pythonPath).resolvingSymlinksInPath().path
        var pythonExecutables = [resolvedPython]
        pythonExecutables.append(contentsOf: Self.pythonRuntimeExecutables(for: resolvedPython))
        for executable in Set(pythonExecutables) {
            profileLines.append("(allow process-exec* (literal \"\(executable)\"))")
        }
        for executable in Self.terminalExecAllowlist {
            profileLines.append("(allow process-exec* (literal \"\(executable)\"))")
        }
        // Lesezugriff im Home-Verzeichnis: Inhalte (file-read-data) sind gesperrt, Metadaten
        // (stat) bleiben erlaubt, damit Python/Matplotlib beim Start nicht scheitern. Freigegeben
        // sind nur das venv und der eigene Arbeitsordner. Die frühere reine Denylist ließ u.a.
        // App-Daten, settings.json, ~/.zsh_history und ~/.config lesbar (Audit 2026-10-12, H-2).
        // Getestet mit dem App-venv: matplotlib-Plot ok, Home-Dateien → PermissionError.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        profileLines.append("(deny file-read-data (subpath \"\(home)\"))")
        profileLines.append("(allow file-read-data (subpath \"\(venvDirectory.path)\"))")
        profileLines.append("(allow file-read-data (subpath \"\(outputDirectory.path)\"))")
        if resolvedPython.hasPrefix(home) {
            let pythonRoot = URL(fileURLWithPath: resolvedPython)
                .deletingLastPathComponent().deletingLastPathComponent().path
            profileLines.append("(allow file-read-data (subpath \"\(pythonRoot)\"))")
        }
        for path in Self.sensitiveReadDenyPaths {
            profileLines.append("(deny file-read* (subpath \"\(path)\"))")
        }

        let profileContent = profileLines.joined(separator: "\n") + "\n"
        try profileContent.write(to: profileURL, atomically: true, encoding: .utf8)
        return profileURL
    }

    /// Der Python-Launcher des macOS-CommandLineTools startet nach dem eigentlichen
    /// `python3.9`-Binary noch `Resources/Python.app/.../Python`. Ohne diese Freigabe meldet
    /// `posix_spawn` nur „Undefined error: 0“, obwohl der Interpreter vorhanden ist.
    private static func pythonRuntimeExecutables(for resolvedPython: String) -> [String] {
        let pythonURL = URL(fileURLWithPath: resolvedPython)
        let versionDirectory = pythonURL
            .deletingLastPathComponent() // bin
            .deletingLastPathComponent() // 3.9
        let candidates = [
            versionDirectory.appendingPathComponent("Resources/Python.app/Contents/MacOS/Python").path
        ]
        return candidates.filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func terminalExecutable(for command: String) -> String? {
        if command == "python3" {
            return fileManager.isExecutableFile(atPath: pythonPath) ? pythonPath : nil
        }
        switch command {
        case "ls": return "/bin/ls"
        case "cat": return "/bin/cat"
        case "pwd": return "/bin/pwd"
        case "grep": return "/usr/bin/grep"
        case "head": return "/usr/bin/head"
        case "tail": return "/usr/bin/tail"
        case "wc": return "/usr/bin/wc"
        case "find": return "/usr/bin/find"
        case "sort": return "/usr/bin/sort"
        case "du": return "/usr/bin/du"
        case "file": return "/usr/bin/file"
        default: return nil
        }
    }

    /// Argumente bleiben absichtlich konservativ: keine Shell-Operatoren, keine absoluten Pfade
    /// außerhalb des Session-Ordners und keine Optionen, die Prozesse starten oder Dateien
    /// löschen könnten. Das Modell kann damit seine Skripte lesen und Fehler lokalisieren, aber
    /// aus `run_command` kein allgemeines Terminal mit Nutzerrechten machen.
    private static func validateTerminalArguments(
        _ arguments: [String], command: String, within directory: URL
    ) throws -> [String] {
        guard arguments.count <= 16 else {
            throw commandError("Zu viele Argumente (maximal 16).")
        }
        guard arguments.allSatisfy({ !$0.contains("\0") && $0.count <= 512 }) else {
            throw commandError("Ein Argument ist leer, enthält ein Nullbyte oder ist zu lang.")
        }

        let safeOptions: Set<String> = [
            "-a", "-l", "-al", "-la", "-1", "-h", "-i", "-n", "-v", "-E", "-F",
            "--", "--line-number", "--ignore-case", "--max-count", "-r", "-R", "-c",
            "-w", "-m", "-t", "-k", "-u", "-d", "-s"
        ]

        switch command {
        case "pwd":
            guard arguments.isEmpty else { throw commandError("pwd akzeptiert keine Argumente.") }
            return []

        case "python3":
            var remaining = arguments
            while let first = remaining.first, first == "-u" || first == "-B" {
                remaining.removeFirst()
            }
            guard remaining.count == 1,
                  remaining[0].lowercased().hasSuffix(".py") else {
                throw commandError("python3 darf nur genau eine .py-Datei aus dem Session-Ordner ausführen.")
            }
            return try arguments.drop(while: { $0 == "-u" || $0 == "-B" })
                .map { try sessionPath($0, within: directory) }

        case "find":
            // Die häufige Form `find . -maxdepth 1 -name "*.py"` wird explizit und ohne
            // Shell-Expansion unterstützt. Optionen, die Befehle starten oder Dateien löschen
            // (z.B. -exec, -delete, -printf), bleiben absichtlich ausgeschlossen.
            enum FindValue {
                case depth
                case name
                case type
            }
            var result: [String] = []
            var expectedValue: FindValue?
            for argument in arguments {
                if let pendingValue = expectedValue {
                    switch pendingValue {
                    case .depth:
                        guard let depth = Int(argument), (0...100).contains(depth) else {
                            throw commandError("find benötigt für -maxdepth/-mindepth eine Zahl zwischen 0 und 100.")
                        }
                    case .name:
                        guard !argument.contains("\0"), !argument.hasPrefix("/") else {
                            throw commandError("Das find-Muster ist ungültig.")
                        }
                    case .type:
                        guard ["f", "d", "l"].contains(argument) else {
                            throw commandError("find -type erlaubt nur f, d oder l.")
                        }
                    }
                    result.append(argument)
                    expectedValue = nil
                    continue
                }

                switch argument {
                case "-maxdepth", "-mindepth":
                    result.append(argument)
                    expectedValue = .depth
                case "-name":
                    result.append(argument)
                    expectedValue = .name
                case "-type":
                    result.append(argument)
                    expectedValue = .type
                case "-print":
                    result.append(argument)
                default:
                    if argument.hasPrefix("-") {
                        throw commandError("Diese find-Option ist nicht freigegeben: \(argument)")
                    }
                    result.append(try sessionPath(argument, within: directory))
                }
            }
            guard expectedValue == nil else {
                throw commandError("Für die letzte find-Option fehlt ein Argument.")
            }
            return result

        case "grep":
            // grep darf ein Suchmuster und danach Dateien bekommen. Nur die Dateipositionen
            // werden als Pfade interpretiert; Muster bleiben normale Argumente ohne Shell-Parsing.
            var result: [String] = []
            var sawPattern = false
            var afterDoubleDash = false
            for argument in arguments {
                if !afterDoubleDash && argument == "--" {
                    afterDoubleDash = true
                    result.append(argument)
                } else if !afterDoubleDash && argument.hasPrefix("-") {
                    guard safeOptions.contains(argument) || argument.hasPrefix("-e") else {
                        throw commandError("Diese grep-Option ist nicht freigegeben: \(argument)")
                    }
                    result.append(argument)
                } else if !sawPattern {
                    sawPattern = true
                    result.append(argument)
                } else {
                    result.append(try sessionPath(argument, within: directory))
                }
            }
            guard sawPattern else { throw commandError("grep benötigt ein Suchmuster.") }
            return result

        default:
            return try arguments.map { argument in
                if argument.hasPrefix("-") {
                    guard safeOptions.contains(argument) else {
                        throw commandError("Diese Option ist für \(command) nicht freigegeben: \(argument)")
                    }
                    return argument
                }
                return try sessionPath(argument, within: directory)
            }
        }
    }

    private static func sessionPath(_ argument: String, within directory: URL) throws -> String {
        let candidate: URL
        if argument.hasPrefix("/") {
            candidate = URL(fileURLWithPath: argument).standardizedFileURL
        } else {
            candidate = URL(fileURLWithPath: argument, relativeTo: directory).standardizedFileURL
        }
        let root = directory.standardizedFileURL.path
        let path = candidate.path
        guard path == root || path.hasPrefix(root + "/") else {
            throw commandError("Der Pfad '\(argument)' liegt außerhalb des Session-Ordners.")
        }
        return path
    }

    private static func commandError(_ message: String) -> NSError {
        NSError(domain: "CodingEnvironment.Command", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func cappedOutput(_ output: String) -> String {
        guard output.count > maxOutputCharacters else { return output }
        let headCount = maxOutputCharacters / 3
        let tailCount = maxOutputCharacters - headCount
        let head = String(output.prefix(headCount))
        let tail = String(output.suffix(tailCount))
        return "\(head)\n[… Ausgabe für den Modellkontext gekürzt …]\n\(tail)"
    }

    /// Installiert ein Python-Paket via pip.
    ///
    /// Sicherheits-Härtung (Audit C6): Der Paketname wird vom LLM gesteuert und pip läuft mit
    /// vollen Nutzerrechten – vorher faktisch modellgesteuerte Remote-Code-Ausführung. Jetzt:
    /// (1) strenge Syntax-Prüfung des Paket-Specs (keine URLs, lokalen Pfade, Shell- oder
    /// pip-Argumente), (2) explizite Nutzer-Bestätigung per Dialog und (3) ein
    /// Minimal-Environment ohne die App-Umgebung (keine evtl. API-Keys).
    func installPackage(_ package: String) async throws -> String {
        let spec = package.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidPackageSpec(spec) else {
            throw NSError(domain: "CodingEnvironment", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                "Ungültiger Paketname: '\(spec)'. Erlaubt sind nur Paketname mit optionaler Version, z.B. 'pandas==2.0'."])
        }
        if !autoInstallPackages {
            guard await Self.requestInstallConfirmation(package: spec) else {
                return "Installation von '\(spec)' wurde vom Nutzer abgelehnt."
            }
        }
        // uv installiert nur fertige Wheels (--only-binary): Es läuft kein Setup-Code des Pakets
        // außerhalb der Sandbox.
        return try await PythonEnvironmentInstaller.shared.installPackage(spec)
    }

    /// Nur "name" oder "name==1.2.3" – alles andere (URLs, git+/lokalen Pfade, -Flags,
    /// Mehrfach-Specs) wird abgelehnt, damit pip nie mit kontrollierbaren Argumenten läuft.
    private static func isValidPackageSpec(_ spec: String) -> Bool {
        let pattern = "^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?(==[A-Za-z0-9][A-Za-z0-9._-]*)?$"
        return spec.range(of: pattern, options: .regularExpression) != nil
    }

    /// Nutzer-Bestätigung für die Paket-Installation (Audit C6): pip lädt Code aus dem Internet
    /// und installiert ihn in das venv – ein bloßes LLM-"Ich brauche Paket X" darf das nicht
    /// automatisch anstoßen.
    private static func requestInstallConfirmation(package: String) async -> Bool {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "Python-Paket installieren?"
            alert.informativeText = "Das Modell möchte das Paket '\(package)' per pip installieren und dafür Code aus dem Internet laden. Fortfahren?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Installieren")
            alert.addButton(withTitle: "Abbrechen")
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    // MARK: - Nicht-blockierende Prozessausführung

    /// Startet einen Prozess und wartet asynchron auf sein Ende (kein `waitUntilExit()`).
    /// Liest stdout/stderr FORTLAUFEND während der Prozess läuft (nicht erst danach) – ein Skript,
    /// das viel Ausgabe erzeugt (Plots, Stacktraces, Base64-Bilder), würde sonst blockieren, sobald
    /// der 64-KB-Pipe-Puffer voll ist und niemand liest, während der Prozess auf freien Platz wartet.
    ///
    /// `timeout`: OHNE dieses Limit wartete diese Funktion früher UNBEGRENZT auf die Prozess-
    /// Beendigung – ein Python-Skript mit Endlosschleife oder ein blockierender Aufruf (z.B. ein
    /// natives GUI-Fenster, siehe Warnung in CodingTool.description) hing dadurch für immer:
    /// der Tool-Call kehrte nie zurück, `isStreaming` blieb dauerhaft `true`, und selbst neue
    /// Nachrichten im selben Chat liefen nur noch in die Warteschlange, ohne je verarbeitet zu
    /// werden. Ein Watchdog-Task terminiert den Prozess nach `timeout` Sekunden zwangsweise,
    /// falls er dann noch läuft – der normale `terminationHandler` bleibt dabei der EINZIGE Pfad,
    /// der die Continuation auflöst (kein Risiko eines doppelten `resume`).
    private func runProcess(_ process: Process, timeout: TimeInterval) async throws -> (output: String, exitCode: Int32, timedOut: Bool) {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let buffer = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { buffer.append(data) }
        }

        return try await withCheckedThrowingContinuation { continuation in
            // Explizites Timeout-Flag statt Raten über .uncaughtSignal (Audit T4): Ein extern
            // getöteter Prozess ist KEIN Timeout. Zusätzlich SIGKILL-Eskalation für Skripte,
            // die SIGTERM ignorieren (Endlosschleife mit Signal-Handler).
            let state = ProcessState()
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled, process.isRunning else { return }
                state.markTimedOut()
                process.terminate() // SIGTERM
                // Gnadenfrist: immer noch am Leben → hart beenden.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard process.isRunning else { return }
                kill(process.processIdentifier, SIGKILL)
            }
            process.terminationHandler = { proc in
                watchdog.cancel()
                pipe.fileHandleForReading.readabilityHandler = nil
                // Prozess ist beendet – keine weiteren Schreibvorgänge möglich, verbleibende
                // Restdaten können jetzt gefahrlos synchron abgeholt werden.
                let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
                if !remaining.isEmpty { buffer.append(remaining) }
                let output = String(data: buffer.data, encoding: .utf8) ?? ""
                continuation.resume(returning: (output, proc.terminationStatus, state.didTimeOut))
            }
            do {
                try process.run()
            } catch {
                watchdog.cancel()
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// Zustandsübergabe zwischen Watchdog-Task und terminationHandler (laufen auf
    /// verschiedenen Threads/Queues – NSLock statt ungeschütztem Bool).
    private final class ProcessState: @unchecked Sendable {
        private let lock = NSLock()
        private var _timedOut = false

        func markTimedOut() {
            lock.lock(); _timedOut = true; lock.unlock()
        }

        var didTimeOut: Bool {
            lock.lock(); defer { lock.unlock() }
            return _timedOut
        }
    }

    /// Session-ID als Pfadkomponente gehärtet (Audit T4): UUIDs sind die Norm, aber der Wert
    /// kommt aus Chat-Daten – ein konstruierter Wert wie "../../x" würde den Output-Ordner
    /// (und damit die Sandbox-Subpaths) verlassen.
    private static func safeSessionID(_ id: String?) -> String {
        guard let id, !id.isEmpty,
              id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return "default_session"
        }
        return id
    }

    /// ExeC-Allowlist der Sandbox (Audit K2) — zugleich die Binaries, die das Terminal-Tool
    /// (run_command) ausführen darf. Bewusst nur read-only Coreutils + der Python-Interpreter:
    /// `/usr/sbin/screencapture` und `pbpaste` sind NICHT enthalten — genau das schließt die
    /// Exfiltrations-Kanäle aus K2. Änderungen hier wirken in Sandbox-Profil UND Terminal-Tool.
    static let terminalExecAllowlist: [String] = [
        "/bin/ls",
        "/bin/cat",
        "/bin/pwd",
        "/usr/bin/grep",
        "/usr/bin/head",
        "/usr/bin/tail",
        "/usr/bin/wc",
        "/usr/bin/find",
        "/usr/bin/sort",
        "/usr/bin/du",
        "/usr/bin/file",
    ]

    /// Sensible Pfade, die die Sandbox dem Skript NICHT lesbar macht (Audit K2/C5).
    /// Gezielte Denylist statt Read-Allowlist (siehe Profildokumentation oben): verhindert
    /// Tokens/Credentials/History-Exfiltration per stdout in den Chat/Modell-Kontext, während
    /// normale Datenanalyse-Reads (z.B. CSV aus ~/Documents) weiter funktionieren.
    static var sensitiveReadDenyPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = [
            "\(home)/.ssh",
            "\(home)/.gnupg",
            "\(home)/.aws",
            "\(home)/.kube",
            "\(home)/.netrc",
            "\(home)/.env",
            "\(home)/Library/Keychains",
            "\(home)/Library/Cookies",
            "\(home)/Library/Safari",
            "\(home)/Library/Mail",
            "\(home)/Library/Messages",
            "\(home)/Library/Application Support/MobileSync",
            "\(home)/Library/Application Support/Google/Chrome",
            "\(home)/Library/Application Support/Firefox",
            "\(home)/Library/Application Support/Microsoft Edge",
            "\(home)/Library/Application Support/1Password",
            "\(home)/Library/Application Support/BraveSoftware",
        ]
        // Eigene App-Daten: enthalten u.a. gespeicherte Sessions mit evtl. sensiblen Inhalten.
        paths.append("\(home)/Library/Application Support/LernAssist/sessions")
        return paths
    }

    /// Thread-sicherer Byte-Akkumulator für den `readabilityHandler`-Callback (läuft auf einer
    /// internen Dispatch-Queue von Foundation, parallel zum `terminationHandler`).
    private final class OutputBuffer: @unchecked Sendable {
        private var _data = Data()
        private let lock = NSLock()

        func append(_ chunk: Data) {
            lock.lock()
            _data.append(chunk)
            lock.unlock()
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return _data
        }
    }
}
