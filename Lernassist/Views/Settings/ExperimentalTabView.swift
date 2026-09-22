import SwiftUI

struct ExperimentalTabView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        // Kein geschachteltes `Form`; SettingsView besitzt bereits den äußeren Scroll-Container.
        VStack(alignment: .leading, spacing: 20) {
            settingsSection(icon: "magnifyingglass.circle", title: "Semantische Suche") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Semantische Suche aktivieren (Experimentell)", isOn: $viewModel.isSemanticSearchEnabled)
                        .toggleStyle(.switch)
                        .help("Nutzt den LM Studio/Ollama Endpoint, um Dokumente semantisch einzubetten und kontextbezogen im Chat abzufragen.")

                    if viewModel.isSemanticSearchEnabled {
                        Text("Wenn aktiviert, werden Dokumente und Bilder aus hochgeladenen Dateien beim Hinzufügen indiziert und durchsucht.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
