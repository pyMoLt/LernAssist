import SwiftUI

// MARK: - ToolsTabView

struct ToolsTabView: View {
    @ObservedObject var viewModel: ChatViewModel
    // Wir nutzen @State für lokale UI-Zustände; Änderungen werden über viewModel.syncToolRegistry() gepusht
    @State private var toolStates: [String: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Tools & Funktionen")
                .font(.headline)

            Text("Deaktivierte Tools tauchen weder im API-Schema noch im System-Prompt auf — sie verbrauchen kein Kontext-Budget und verwirren das Modell nicht.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            ForEach(ToolRegistry.shared.tools, id: \.name) { tool in
                ToolToggleRow(tool: tool, isEnabled: binding(for: tool))
            }

            if toolStates["run_command"] == true {
                Text("Das begrenzte Terminal arbeitet nur im temporären Sitzungsordner und fragt vor jedem einzelnen Aufruf nach deiner Bestätigung. Es gibt keinen Shell-String und keine freigegebenen Lösch- oder Netzwerkbefehle.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, -8)
            }

            Divider()

            // Konfiguration von SearXNG-URL und Zeichen-Limit lebt NUR noch im Websuche-Tab
            // (Audit P3): Vorher standen hier dieselben Felder noch einmal – zwei Bindings auf
            // dieselben Properties verstellten sich gegenseitig und verwässerten die Zuständig-
            // keit (der Websuche-Tab bietet zusätzlich den Ping-Test, den es hier nie gab).
            if toolStates["web_search"] == true || toolStates["browse_url"] == true {
                GroupBox("Web-Suche & URL-Browsing") {
                    Text("SearXNG-URL und das Zeichen-Limit fürs URL-Browsing werden im Tab „Websuche“ konfiguriert.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .onAppear { loadStates() }
        .onChange(of: toolStates) { _ in applyStates() }
    }

    // MARK: - Binding-Helfer

    private func binding(for tool: AppTool) -> Binding<Bool> {
        Binding(
            get: { toolStates[tool.name] ?? tool.isEnabled },
            set: { newVal in
                toolStates[tool.name] = newVal
                tool.isEnabled = newVal
                viewModel.saveSettings()
                viewModel.syncToolRegistry()
                // WebSearch-Enable auch in ViewModel-Property spiegeln (für Abwärtskompatibilität)
                if tool.name == "web_search" { viewModel.searchEnabled = newVal }
            }
        )
    }

    private func loadStates() {
        toolStates = Dictionary(uniqueKeysWithValues: ToolRegistry.shared.tools.map { ($0.name, $0.isEnabled) })
    }

    private func applyStates() {
        ToolRegistry.shared.loadEnabledStates(from: toolStates)
        viewModel.syncToolRegistry()
    }
}

// MARK: - Tool-Zeile

private struct ToolToggleRow: View {
    let tool: AppTool
    @Binding var isEnabled: Bool

    var body: some View {
        HStack(alignment: .top) {
            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 3) {
                Text(tool.displayName)
                    .font(.body.weight(.medium))
                Text(tool.name)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
