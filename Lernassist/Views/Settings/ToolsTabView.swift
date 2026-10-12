import SwiftUI

// MARK: - ToolsTabView

struct ToolsTabView: View {
    @ObservedObject var viewModel: ChatViewModel
    // Wir nutzen @State für lokale UI-Zustände; Änderungen werden über viewModel.syncToolRegistry() gepusht
    @State private var toolStates: [String: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            settingsSection(icon: "wrench.and.screwdriver", title: "Tools & Funktionen") {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text("Deaktivierte Tools tauchen weder im API-Schema noch im System-Prompt auf – sie verbrauchen kein Kontext-Budget und verwirren das Modell nicht.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(ToolRegistry.shared.tools, id: \.name) { tool in
                        Divider()
                        ToolToggleRow(tool: tool, isEnabled: binding(for: tool))
                    }
                }
            }

            // Konfiguration von SearXNG-URL und Zeichen-Limit lebt nur im Tab „Recherche“.
            if toolStates["coding_sandbox"] ?? true {
                settingsSection(icon: "terminal", title: "Python-Umgebung (coding_sandbox)") {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        HStack {
                            Image(systemName: pythonStatusSymbol)
                                .foregroundStyle(pythonStatusColor)
                            Text(viewModel.pythonEnvironmentStatus.label)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Neu einrichten") { viewModel.setupPythonEnvironment(force: true) }
                                .controlSize(.small)
                                .disabled({ if case .installing = viewModel.pythonEnvironmentStatus { return true }; return false }())
                        }
                        Text("Eigenes Python \(PythonEnvironmentInstaller.pythonVersion) (über uv), unabhängig vom System-Python. Vorinstalliert: \(PythonEnvironmentInstaller.basePackages.joined(separator: ", ")).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle("Weitere Pakete ohne Rückfrage installieren", isOn: $viewModel.autoInstallPythonPackages)
                            .toggleStyle(.switch)
                            .font(.caption)
                            .settingHelp("Das Modell kann fehlende Pakete selbst nachinstallieren (nur fertige Pakete von PyPI, kein Setup-Code). Aus = jedes Mal nachfragen.")
                    }
                }
            }

            if toolStates["web_search"] == true || toolStates["browse_url"] == true {
                settingsSection(icon: "magnifyingglass", title: "Websuche & URL-Browsing") {
                    Text("SearXNG-URL, Quellen und das Zeichen-Limit fürs URL-Browsing werden im Tab „Recherche“ konfiguriert.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { loadStates() }
        .onChange(of: toolStates) { _ in applyStates() }
    }

    private var pythonStatusSymbol: String {
        switch viewModel.pythonEnvironmentStatus {
        case .ready: return "checkmark.circle.fill"
        case .installing: return "arrow.down.circle"
        case .failed: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var pythonStatusColor: Color {
        switch viewModel.pythonEnvironmentStatus {
        case .ready: return .green
        case .installing: return .accentColor
        case .failed: return .orange
        case .unknown: return .secondary
        }
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
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
