import SwiftUI
import AppKit

// MARK: - SettingsView

/// Einstellungsfenster mit eigener, leichter Navigation statt einer verschachtelten AppKit-List.
/// Damit bleiben Auswahl, Scrollen und der Layout-Host vollständig in SwiftUI und die einzelne
/// Content-ScrollView ist die einzige scrollbare Ebene der Tab-Inhalte.
struct SettingsView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: SettingsTab
    @State private var isHelpModeActive = false
    @AppStorage("hasSeenHelpIntro") private var hasSeenHelpIntro = false

    init(viewModel: ChatViewModel, initialTab: String? = nil) {
        self.viewModel = viewModel
        self._selectedTab = State(initialValue: SettingsTab(rawValue: initialTab ?? "") ?? .endpoints)
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider()
                HStack(spacing: 0) {
                    navigation
                    Divider()
                    content
                }
                footer
            }
            helpIntro
        }
        .frame(width: 920, height: 640)
        .onReceive(NotificationCenter.default.publisher(for: .debugSwitchSettingsTab)) { note in
            if let rawTab = note.userInfo?["tab"] as? String,
               let tab = SettingsTab(rawValue: rawTab) {
                selectedTab = tab
            }
        }
        .environment(\.isHelpModeActive, isHelpModeActive)
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: DS.Space.m) {
            ZStack {
                Circle()
                    .fill(DS.Ink.accent.opacity(0.13))
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DS.Ink.accent.gradient)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text("Einstellungen")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                Text(selectedTab.navigationSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isHelpModeActive {
                Label("Hilfe aktiv", systemImage: "questionmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(DS.Ink.accent)
                    .padding(.horizontal, DS.Space.s)
                    .padding(.vertical, DS.Space.xs)
                    .background(Capsule().fill(DS.Surface.selection))
            }

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isHelpModeActive.toggle()
                }
            } label: {
                Image(systemName: isHelpModeActive ? "questionmark.circle.fill" : "questionmark.circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isHelpModeActive ? DS.Ink.accent : .secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help("Hilfe-Modus umschalten")

            Button(action: finish) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(DS.Surface.chip))
            }
            .buttonStyle(.plain)
            .help("Einstellungen schließen")
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.m)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            navigationGroup("Konfiguration", tabs: [.endpoints, .model, .learning, .search, .tools])
            navigationGroup("App", tabs: [.hotkeys, .advanced, .appearance, .experimental])
            Spacer(minLength: 0)
            Label("Änderungen werden lokal gespeichert", systemImage: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DS.Space.xs)
        }
        .padding(DS.Space.m)
        .frame(width: 215, alignment: .leading)
        .background(DS.Surface.navigation)
    }

    private func navigationGroup(_ title: String, tabs: [SettingsTab]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, DS.Space.s)

            ForEach(tabs) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 18)
                        Text(tab.title)
                            .font(.system(.subheadline, design: .rounded).weight(selectedTab == tab ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(selectedTab == tab ? DS.Ink.accent : DS.Ink.primary)
                    .padding(.horizontal, DS.Space.s)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                            .fill(selectedTab == tab ? DS.Surface.selection : .clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                            .stroke(selectedTab == tab ? DS.Ink.accent.opacity(0.18) : .clear, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-tab-\(tab.rawValue)")
            }
        }
    }

    private var content: some View {
        ScrollView {
            selectedTabContent
                .frame(maxWidth: 650, alignment: .leading)
                .padding(.horizontal, DS.Space.xxl)
                .padding(.vertical, DS.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.34))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var selectedTabContent: some View {
        switch selectedTab {
        case .endpoints: EndpointsTabView(viewModel: viewModel)
        case .model: ModelTabView(viewModel: viewModel)
        case .learning: LearningModeTabView(viewModel: viewModel)
        case .search: SearchTabView(viewModel: viewModel)
        case .hotkeys: HotkeysTabView(viewModel: viewModel)
        case .tools: ToolsTabView(viewModel: viewModel)
        case .advanced: AdvancedTabView(viewModel: viewModel)
        case .appearance: AppearanceTabView(viewModel: viewModel)
        case .experimental: ExperimentalTabView(viewModel: viewModel)
        }
    }

    private var footer: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Einstellungen werden beim Schließen gespeichert")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Fertig", action: finish)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.m)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var helpIntro: some View {
        if isHelpModeActive && !hasSeenHelpIntro {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .allowsHitTesting(true)

            VStack(spacing: DS.Space.l) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(DS.Ink.accent.gradient)
                Text("Hilfe-Modus aktiviert")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                Text("Bewege den Mauszeiger über markierte Elemente, um Hinweise zu sehen. Solange dieser Modus aktiv ist, sind Änderungen geschützt.")
                    .multilineTextAlignment(.center)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Verstanden") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        hasSeenHelpIntro = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(DS.Space.xxl)
            .frame(width: 410)
            .background(AppCard { EmptyView() })
            .transition(.scale.combined(with: .opacity))
        }
    }

    private func finish() {
        viewModel.saveSettings()
        dismiss()
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case endpoints = "Endpoints"
    case model = "Model"
    case learning = "Learning"
    case search = "Search"
    case hotkeys = "Hotkeys"
    case tools = "Tools"
    case advanced = "Advanced"
    case appearance = "Appearance"
    case experimental = "Experimental"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .endpoints: "Endpunkte"
        case .model: "Modell"
        case .learning: "Lernmodus"
        case .search: "Websuche"
        case .hotkeys: "Hotkeys"
        case .tools: "Tools"
        case .advanced: "Erweitert"
        case .appearance: "Erscheinungsbild"
        case .experimental: "Experimentell"
        }
    }

    var icon: String {
        switch self {
        case .endpoints: "network"
        case .model: "cpu"
        case .learning: "brain"
        case .search: "magnifyingglass"
        case .hotkeys: "keyboard"
        case .tools: "wrench.and.screwdriver"
        case .advanced: "gearshape.2"
        case .appearance: "paintpalette"
        case .experimental: "flask"
        }
    }

    var navigationSubtitle: String {
        switch self {
        case .endpoints: "Verbindungen und Profile"
        case .model: "Modell und Kontext"
        case .learning: "Lernstil und Antworten"
        case .search: "Websuche und Browsing"
        case .hotkeys: "Schnellzugriffe"
        case .tools: "Werkzeuge und Berechtigungen"
        case .advanced: "Hintergrund und Kontext"
        case .appearance: "Darstellung und Verhalten"
        case .experimental: "Neue Funktionen testen"
        }
    }
}
