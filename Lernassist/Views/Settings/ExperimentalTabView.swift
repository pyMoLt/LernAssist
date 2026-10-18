import SwiftUI

struct ExperimentalTabView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            settingsSection(icon: "flask.fill", title: "Experimentelle Funktionen", tint: DS.Accent.amber) {
                SettingsRow(
                    title: "Semantische Dokumentensuche (RAG / Embeddings)",
                    subtitle: "Indiziert hochgeladene Dokumente lokal über den Embedding-Endpunkt für kontextbezogene Abfragen.",
                    icon: "sparkle.magnifyingglass",
                    tint: DS.Accent.amber
                ) {
                    Toggle("", isOn: $viewModel.isSemanticSearchEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .help("Nutzt den LM Studio/Ollama Endpoint, um Dokumente semantisch einzubetten und kontextbezogen im Chat abzufragen.")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
