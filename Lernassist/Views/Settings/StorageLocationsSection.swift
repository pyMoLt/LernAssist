import AppKit
import SwiftUI

/// Einstellungen → Erweitert → Speicherorte: Wo Chats, Bilder, Python-Dateien und interaktive
/// Ausgaben liegen – mit Größe und direktem Sprung in den Finder.
struct StorageLocationsSection: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var sizes: [String: Int64] = [:]
    @State private var confirmClearWorkFiles = false

    private struct Location: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let url: URL
    }

    private var locations: [Location] {
        [
            Location(id: "root", title: L("Datenordner"), subtitle: L("Alles von LernAssist: Einstellungen, Chats, Bilder, Python."),
                     icon: "folder", url: AppStorageLocation.root),
            Location(id: "sessions", title: L("Chats"), subtitle: L("Ein JSON pro Chat."),
                     icon: "bubble.left.and.bubble.right", url: AppStorageLocation.sessionsDir),
            Location(id: "archive", title: L("Archiv"), subtitle: L("Archivierte Chats."),
                     icon: "archivebox", url: AppStorageLocation.archiveDir),
            Location(id: "images", title: L("Bilder"), subtitle: L("Screenshots, Plots, Abbildungen aus der Recherche, Kartenbilder."),
                     icon: "photo.on.rectangle", url: AppStorageLocation.imagesDir),
            Location(id: "coding", title: L("Python-Arbeitsordner"), subtitle: L("Pro Chat: Skripte, Downloads und interaktive Ausgaben (Ordner „Ausgaben“)."),
                     icon: "chevron.left.forwardslash.chevron.right", url: CodingEnvironment.shared.outputDirectory),
            Location(id: "pythonEnv", title: L("Python-Umgebung"), subtitle: L("Python 3.12 und die installierten Pakete."),
                     icon: "shippingbox", url: PythonEnvironmentInstaller.root),
        ]
    }

    var body: some View {
        settingsSection(icon: "externaldrive.fill", title: L("Speicherorte"), tint: DS.Accent.blue) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                ForEach(Array(locations.enumerated()), id: \.element.id) { index, location in
                    if index > 0 { SettingsHairline() }
                    SettingsRow(title: location.title, subtitle: location.subtitle, icon: location.icon, tint: DS.Accent.blue,
                                help: location.url.path) {
                        HStack(spacing: DS.Space.s) {
                            Text(sizes[location.id].map(Self.format) ?? "…")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 62, alignment: .trailing)
                            Button(L("Öffnen")) { open(location.url) }
                                .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.blue))
                                .help(L("Im Finder öffnen: \(location.url.path)"))
                        }
                    }
                }

                SettingsHairline()

                HStack(spacing: DS.Space.s) {
                    Button(L("Arbeitsordner dieses Chats")) { openCurrentChatFolder() }
                        .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.blue))
                        .disabled(viewModel.activeSession == nil)
                        .help(L("Skripte, Downloads und HTML-Ausgaben des geöffneten Chats"))
                    Spacer()
                    Button(L("Python-Arbeitsdateien leeren …")) { confirmClearWorkFiles = true }
                        .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.rose))
                        .help(L("Legt alle Python-Arbeitsordner in den Papierkorb (Chats und Bilder bleiben)."))
                }
            }
        }
        .task { await refreshSizes() }
        .confirmationDialog(L("Python-Arbeitsdateien in den Papierkorb legen?"), isPresented: $confirmClearWorkFiles) {
            Button(L("In den Papierkorb"), role: .destructive) { clearWorkFiles() }
        } message: {
            Text(L("Skripte, Downloads und gespeicherte HTML-Ausgaben aller Chats wandern in den Papierkorb. Die Ausgaben bleiben im Chat sichtbar und werden beim Öffnen neu gespeichert."))
        }
    }

    private func open(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private func openCurrentChatFolder() {
        guard let session = viewModel.activeSession else { return }
        open(CodingEnvironment.shared.outputDirectory.appendingPathComponent(session.id.uuidString, isDirectory: true))
    }

    private func clearWorkFiles() {
        let folder = CodingEnvironment.shared.outputDirectory
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        NSWorkspace.shared.recycle(items) { _, _ in
            Task { @MainActor in await refreshSizes() }
        }
    }

    private func refreshSizes() async {
        let targets = locations.map { ($0.id, $0.url) }
        let result = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: targets.map { ($0.0, Self.folderSize($0.1)) })
        }.value
        sizes = result
    }

    nonisolated private static func folderSize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    nonisolated private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
