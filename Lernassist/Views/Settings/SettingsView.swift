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

    /// Schließt das eigenständige Einstellungsfenster (nil = als Sheet präsentiert).
    var onClose: (() -> Void)? = nil

    init(viewModel: ChatViewModel, initialTab: String? = nil, onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        self.viewModel = viewModel
        self._selectedTab = State(initialValue: SettingsTab(rawValue: initialTab ?? "") ?? .endpoints)
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                HStack(spacing: 0) {
                    navigation
                    content
                }
                footer
            }
            helpIntro
        }
        .background(DS.Surface.canvas)
        .frame(minWidth: 780, idealWidth: 940, minHeight: 540, idealHeight: 660)
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
            LernAssistBrandIcon(size: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text("Einstellungen")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                Text(selectedTab.navigationSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isHelpModeActive {
                Label("Info-Modus: Einstellung überfahren", systemImage: "info.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(DS.Accent.indigo)
                    .padding(.horizontal, DS.Space.s)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(DS.Surface.selection))
            }

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isHelpModeActive.toggle()
                }
            } label: {
                Image(systemName: isHelpModeActive ? "info.circle.fill" : "info.circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isHelpModeActive ? DS.Accent.indigo : .secondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(isHelpModeActive ? DS.Surface.selection : DS.Surface.control))
            }
            .buttonStyle(.plain)
            .help("Info-Modus: Erklärungen zu jeder Einstellung beim Überfahren")
            .accessibilityLabel(isHelpModeActive ? "Info-Modus ausschalten" : "Info-Modus einschalten")

            Button(action: finish) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(DS.Surface.control))
            }
            .buttonStyle(.plain)
            .help("Einstellungen schließen")
            .accessibilityLabel("Einstellungen schließen")
            .accessibilityLabel("Einstellungen schließen")
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.m)
        .background(DS.Surface.canvas)
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            navigationGroup("Konfiguration", tabs: [.endpoints, .model, .search, .tools, .learning])
            navigationGroup("System & App", tabs: [.hotkeys, .appearance, .advanced, .experimental])
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield.fill")
                        .font(.caption2)
                        .foregroundStyle(DS.Accent.emerald)
                    Text("Lokal gespeichert")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(AppVersion.display)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, DS.Space.s)
        }
        .padding(DS.Space.m)
        .frame(width: 224, alignment: .leading)
        .background(DS.Surface.sidebar)
    }

    private func navigationGroup(_ title: String, tabs: [SettingsTab]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, DS.Space.s)
                .padding(.bottom, 2)

            ForEach(tabs) { tab in
                let isSelected = selectedTab == tab
                Button {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: DS.Space.s) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(tab.tint.opacity(isSelected ? 0.22 : 0.12))
                                .frame(width: 24, height: 24)
                            Image(systemName: tab.icon)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(tab.tint)
                        }
                        Text(tab.title)
                            .font(.system(.subheadline, design: .rounded).weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? DS.Ink.primary : .secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DS.Space.s)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                            .fill(isSelected ? DS.Surface.selection : .clear)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-tab-\(tab.rawValue)")
            }
        }
    }

    private var content: some View {
        ScrollView(.vertical) {
            selectedTabContent
                .frame(maxWidth: 660, alignment: .leading)
                .padding(.horizontal, DS.Space.xxl)
                .padding(.vertical, DS.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.Surface.canvas)
        .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
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
                .foregroundStyle(DS.Accent.emerald)
            Text("Einstellungen werden automatisch übernommen")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Fertig", action: finish)
                .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.indigo, prominent: true))
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.m)
        .background(DS.Surface.canvas)
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
                    .foregroundStyle(DS.Accent.brandGradient)
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
                .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.indigo, prominent: true))
            }
            .padding(DS.Space.xxl)
            .frame(width: 410)
            .background(AppCard { EmptyView() })
            .transition(.scale.combined(with: .opacity))
        }
    }

    private func finish() {
        viewModel.saveSettings()
        if let onClose { onClose() } else { dismiss() }
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
        case .model: "Modell & KI"
        case .learning: "Lernmodus"
        case .search: "Recherche"
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

    var tint: Color {
        switch self {
        case .endpoints: DS.Accent.blue
        case .model: DS.Accent.indigo
        case .learning: DS.Accent.amber
        case .search: DS.Accent.cyan
        case .hotkeys: DS.Accent.rose
        case .tools: DS.Accent.emerald
        case .advanced: DS.Accent.indigo
        case .appearance: DS.Accent.cyan
        case .experimental: DS.Accent.amber
        }
    }

    var navigationSubtitle: String {
        switch self {
        case .endpoints: "Server-Verbindungen, Profile und direkte Modellwahl"
        case .model: "Modell-Parameter, Kontextfenster und Hintergrund-Jobs"
        case .learning: "Didaktik, Lernstil und Antwortverhalten"
        case .search: "Websuche, Quellen und lokales Browsing"
        case .hotkeys: "Globale Tastenkürzel für schnellen Zugriff"
        case .tools: "Werkzeuge, System-Integration und Berechtigungen"
        case .advanced: "Hintergrund-Verarbeitung und Diagnose"
        case .appearance: "Darstellung, Schriftgröße und Fensterverhalten"
        case .experimental: "Vorschau-Funktionen und Labor-Optionen"
        }
    }
}


/// Versionsanzeige aus dem App-Bundle (MARKETING_VERSION + Build).
enum AppVersion {
    static var display: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "LernAssist \(version) (\(build))"
    }
}
