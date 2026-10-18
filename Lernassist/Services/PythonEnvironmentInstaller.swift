import Foundation
import CryptoKit
import os

/// Zustand der Python-Umgebung für `coding_sandbox` (in den Einstellungen sichtbar).
enum PythonEnvironmentStatus: Equatable {
    case unknown
    case installing(step: String)
    case ready(version: String)
    case failed(String)

    var label: String {
        switch self {
        case .unknown:                 return "Nicht geprüft"
        case .installing(let step):    return "Wird eingerichtet: \(step)"
        case .ready(let version):      return "Bereit (Python \(version))"
        case .failed(let message):     return "Fehler: \(message)"
        }
    }
}

/// Richtet eine eigene, aktuelle Python-Umgebung ein – unabhängig vom System-Python (macOS liefert
/// nur 3.9, und das nur mit den Xcode Command Line Tools). Muster aus PdfAndDocs (EngineInstaller):
///
/// 1. `uv` finden (lokal installiert) oder einmalig von den offiziellen GitHub-Releases laden
///    (Version fest, SHA-256 geprüft)
/// 2. `uv python install 3.12` → python-build-standalone im App-Ordner
/// 3. Mach-O-Signaturen prüfen und ggf. ad hoc neu signieren (uv patcht libpython; ohne gültige
///    Signatur beendet macOS den Interpreter beim Start)
/// 4. Interpreter testweise starten, venv anlegen, Grundpakete als fertige Wheels installieren
///
/// Alles liegt unter `~/Library/Application Support/LernAssist/python-env`.
actor PythonEnvironmentInstaller {
    static let shared = PythonEnvironmentInstaller()

    static let pythonVersion = "3.12"
    static let uvVersion = "0.8.5"
    private static let uvChecksums = [
        "aarch64": "467e875ac84ac2155f048b56e33741d7dee6f02369048d5b6c05b74b745411e2",
        "x86_64": "9ee5b34975ab4659345fc96cc08098d7ec871cdfa969a5774894bcaebdaf3b58",
    ]

    /// Grundstock für Lernen, Datenauswertung und Grafiken (nur Wheels, ~250 MB).
    static let basePackages = ["numpy", "pandas", "scipy", "sympy", "matplotlib", "seaborn",
                               "openpyxl", "statsmodels", "networkx", "pillow", "requests"]

    static var root: URL { AppStorageLocation.root.appendingPathComponent("python-env", isDirectory: true) }
    static var venv: URL { root.appendingPathComponent("venv", isDirectory: true) }
    static var venvPython: URL { venv.appendingPathComponent("bin/python3") }
    private static var pythonDirectory: URL { root.appendingPathComponent("python", isDirectory: true) }
    private static var marker: URL { root.appendingPathComponent("ready.json") }
    private static var bundledUV: URL { root.appendingPathComponent("tools/uv") }

    private var installTask: Task<Void, Error>?

    /// Ist die Umgebung vollständig eingerichtet?
    static var isReady: Bool {
        FileManager.default.isExecutableFile(atPath: venvPython.path) && FileManager.default.fileExists(atPath: marker.path)
    }

    static var readyVersion: String? {
        guard isReady, let data = try? Data(contentsOf: marker),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["python"] as? String
    }

    /// Startet die Einrichtung (einmalig, parallel aufrufbar). `onStatus` meldet den Fortschritt.
    func ensureInstalled(force: Bool = false, onStatus: @escaping @Sendable (PythonEnvironmentStatus) -> Void) async {
        if !force, Self.isReady {
            // Neu hinzugekommene Grundpakete (z. B. requests für Downloads) einmalig nachinstallieren.
            await installMissingBasePackages(onStatus: onStatus)
            onStatus(.ready(version: Self.readyVersion ?? Self.pythonVersion))
            return
        }
        if let installTask {
            _ = try? await installTask.value
            onStatus(Self.isReady ? .ready(version: Self.readyVersion ?? Self.pythonVersion) : .failed("Einrichtung abgebrochen"))
            return
        }
        let task = Task { try await self.install(force: force, onStatus: onStatus) }
        installTask = task
        do {
            try await task.value
            onStatus(.ready(version: Self.readyVersion ?? Self.pythonVersion))
        } catch {
            AppLog.services.error("Python-Umgebung: \(error.localizedDescription)")
            onStatus(.failed(error.localizedDescription))
        }
        installTask = nil
    }

    private func install(force: Bool, onStatus: @escaping @Sendable (PythonEnvironmentStatus) -> Void) async throws {
        let fm = FileManager.default
        if force { try? fm.removeItem(at: Self.root) }
        try fm.createDirectory(at: Self.root, withIntermediateDirectories: true)

        onStatus(.installing(step: "uv bereitstellen"))
        let uv = try await locateOrDownloadUV()

        let env = uvEnvironment()
        onStatus(.installing(step: "Python \(Self.pythonVersion) installieren"))
        try await Self.run(uv, ["python", "install", Self.pythonVersion, "--no-bin"], environment: env)

        onStatus(.installing(step: "Signaturen prüfen"))
        let repaired = try await Self.repairSignatures(in: Self.pythonDirectory)
        if repaired > 0 { AppLog.services.info("Python-Umgebung: \(repaired) Datei(en) neu signiert") }

        guard let interpreter = Self.interpreter(in: Self.pythonDirectory) else {
            throw Self.error("Python fehlt nach der Installation.")
        }
        try await Self.run(interpreter, ["-c", "import ssl, sqlite3, ctypes"], environment: [:])

        onStatus(.installing(step: "Umgebung anlegen"))
        try await Self.run(uv, ["venv", "--python", interpreter.path, "--allow-existing", Self.venv.path], environment: env)

        onStatus(.installing(step: "Pakete installieren (\(Self.basePackages.count))"))
        try await Self.run(uv, ["pip", "install", "--python", Self.venvPython.path, "--only-binary", ":all:"] + Self.basePackages,
                           environment: env, timeout: 900)

        onStatus(.installing(step: "Pakete prüfen"))
        let version = try await Self.run(Self.venvPython, ["-c", "import sys, numpy, pandas, matplotlib; print('%d.%d.%d' % sys.version_info[:3])"],
                                         environment: [:]).trimmingCharacters(in: .whitespacesAndNewlines)
        let markerData = try JSONSerialization.data(withJSONObject: [
            "python": version, "uv": Self.uvVersion, "packages": Self.basePackages,
            "installed": ISO8601DateFormatter().string(from: Date()),
        ])
        try markerData.write(to: Self.marker, options: .atomic)
    }

    /// Grundpakete, die nach der Einrichtung zur Liste hinzukamen, ohne Neu-Einrichtung ergänzen.
    private func installMissingBasePackages(onStatus: @escaping @Sendable (PythonEnvironmentStatus) -> Void) async {
        guard let data = try? Data(contentsOf: Self.marker),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let installed = Set(json["packages"] as? [String] ?? [])
        let missing = Self.basePackages.filter { !installed.contains($0) }
        guard !missing.isEmpty, let uv = try? await locateOrDownloadUV() else { return }
        onStatus(.installing(step: "Pakete ergänzen (\(missing.joined(separator: ", ")))"))
        do {
            _ = try await Self.run(uv, ["pip", "install", "--python", Self.venvPython.path, "--only-binary", ":all:"] + missing,
                                   environment: uvEnvironment(), timeout: 300)
            json["packages"] = Self.basePackages
            if let updated = try? JSONSerialization.data(withJSONObject: json) {
                try? updated.write(to: Self.marker, options: .atomic)
            }
        } catch {
            AppLog.services.error("Python-Umgebung: Pakete ergänzen fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    /// Installiert ein Paket als fertiges Wheel (kein Ausführen fremder Setup-Skripte).
    func installPackage(_ spec: String) async throws -> String {
        guard Self.isReady else { throw Self.error("Die Python-Umgebung ist noch nicht eingerichtet.") }
        let uv = try await locateOrDownloadUV()
        return try await Self.run(uv, ["pip", "install", "--python", Self.venvPython.path, "--only-binary", ":all:", spec],
                                  environment: uvEnvironment(), timeout: 300)
    }

    private func uvEnvironment() -> [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": Self.root.path,
            "TMPDIR": NSTemporaryDirectory(),
            "UV_PYTHON_INSTALL_DIR": Self.pythonDirectory.path,
            "UV_PYTHON_PREFERENCE": "only-managed",
            "UV_CACHE_DIR": Self.root.appendingPathComponent("cache").path,
            "UV_NO_PROGRESS": "1",
            "NO_COLOR": "1",
        ]
    }

    // MARK: uv

    private func locateOrDownloadUV() async throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [Self.bundledUV.path, "\(home)/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            if (try? await Self.run(URL(fileURLWithPath: path), ["--version"], environment: [:])) != nil {
                return URL(fileURLWithPath: path)
            }
        }
        return try await downloadUV()
    }

    private func downloadUV() async throws -> URL {
        #if arch(arm64)
        let arch = "aarch64"
        #else
        let arch = "x86_64"
        #endif
        guard let expected = Self.uvChecksums[arch],
              let url = URL(string: "https://github.com/astral-sh/uv/releases/download/\(Self.uvVersion)/uv-\(arch)-apple-darwin.tar.gz") else {
            throw Self.error("Keine uv-Version für diese Architektur.")
        }
        let (file, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Self.error("uv-Download fehlgeschlagen.") }
        let digest = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        guard digest == expected else { throw Self.error("uv-Download hat eine falsche Prüfsumme – abgebrochen.") }

        let tools = Self.bundledUV.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let extractDir = tools.appendingPathComponent("extract")
        try? FileManager.default.removeItem(at: extractDir)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try await Self.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", file.path, "-C", extractDir.path], environment: [:])
        let extracted = extractDir.appendingPathComponent("uv-\(arch)-apple-darwin/uv")
        try? FileManager.default.removeItem(at: Self.bundledUV)
        try FileManager.default.moveItem(at: extracted, to: Self.bundledUV)
        try? FileManager.default.removeItem(at: extractDir)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.bundledUV.path)
        return Self.bundledUV
    }

    // MARK: Hilfen (Port aus PdfAndDocs EngineInstaller)

    static func interpreter(in directory: URL) -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.lastPathComponent.hasPrefix("cpython-\(pythonVersion)") }
            .sorted { $0.path > $1.path }
            .map { $0.appendingPathComponent("bin/python\(pythonVersion)") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func repairSignatures(in directory: URL) async throws -> Int {
        let codesign = URL(fileURLWithPath: "/usr/bin/codesign")
        var repaired = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        let urls = (FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys)?.allObjects as? [URL]) ?? []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, values?.isSymbolicLink != true, isMachO(url) else { continue }
            if (try? await run(codesign, ["--verify", url.path], environment: [:])) != nil { continue }
            if (try? await run(codesign, ["--force", "--sign", "-", url.path], environment: [:])) != nil { repaired += 1 }
        }
        return repaired
    }

    static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        let magic = head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return [0xFEEDFACF, 0xCFFAEDFE, 0xFEEDFACE, 0xCEFAEDFE, 0xCAFEBABE, 0xBEBAFECA].contains(magic)
    }

    /// Startet ein Programm, sammelt die Ausgabe und wirft bei Exit-Code ≠ 0.
    @discardableResult
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String],
                    timeout: TimeInterval = 300) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if !environment.isEmpty { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let collector = OutputCollector()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collector.append(data) }
        }
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning { process.terminate() }
        }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        watchdog.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd() { collector.append(rest) }
        let output = collector.text
        guard status == 0 else {
            throw error("\(executable.lastPathComponent) \(arguments.first ?? "") fehlgeschlagen: \(output.suffix(400))")
        }
        return output
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "PythonEnvironment", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}
