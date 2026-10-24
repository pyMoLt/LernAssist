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
    @State private var searchText = ""
    /// Sprungziel der Suche (Titel und Abschnitt in der aktuellen Sprache).
    @State private var highlight: String? = nil
    @State private var highlightSection: String? = nil
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
            HStack(spacing: 0) {
                navigation
                content
            }
            helpIntro
        }
        .background {
            ColorFieldBackground(accent: viewModel.appearance.accent, background: viewModel.appearance.background)
        }
        .appAppearance(viewModel.appearance, language: viewModel.appLanguage)
        .frame(minWidth: 820, idealWidth: 1000, minHeight: 560, idealHeight: 700)
        .onReceive(NotificationCenter.default.publisher(for: .debugSwitchSettingsTab)) { note in
            if let rawTab = note.userInfo?["tab"] as? String,
               let tab = SettingsTab(rawValue: rawTab) {
                selectedTab = tab
            }
        }
        .onDisappear { viewModel.saveSettings() }
        .environment(\.isHelpModeActive, isHelpModeActive)
    }

    // MARK: Seitenleiste (Karte wie in der Vorlage)

    private var navigation: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                LernAssistBrandIcon(size: 24)
                Text(L("LernAssist"))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.bottom, DS.Space.xs)

            searchField

            if searchText.trimmingCharacters(in: .whitespaces).count >= 2 {
                searchResults
            } else {
                navigationGroup(L("Verbindung"), tabs: [.endpoints, .model, .models])
                navigationGroup(L("Lernen"), tabs: [.learning, .search, .tools])
                navigationGroup("App", tabs: [.appearance, .hotkeys, .advanced])
            }
            Spacer(minLength: 0)
            Text(AppVersion.display)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .padding(.horizontal, DS.Space.s)
        }
        .padding(.top, 44) // Platz für die Fensterknöpfe
        .padding(.horizontal, DS.Space.s)
        .padding(.bottom, DS.Space.m)
        .frame(width: 236, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassSurface(cornerRadius: 11, elevated: true)
        .padding(.leading, 6)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .ignoresSafeArea(.container, edges: .top)
    }

    // MARK: Suche

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(L("Einstellungen durchsuchen"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .rounded))
            if !searchText.isEmpty {
                Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Suche leeren"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DS.Surface.control))
        .padding(.bottom, DS.Space.xs)
    }

    /// Treffer in der aktuellen Sprache (Titel und Untertitel; deutsche Begriffe finden immer).
    private var matches: [SettingsSearchIndex.Entry] {
        let words = searchText.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return SettingsSearchIndex.entries.filter { entry in
            let text = (L(dynamic: entry.title) + " " + L(dynamic: entry.subtitle) + " " + entry.title).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    private var searchResults: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                let found = matches
                if found.isEmpty {
                    Text(L("Keine Treffer")).font(.caption).foregroundStyle(.secondary).padding(DS.Space.s)
                }
                ForEach(found, id: \.self) { entry in
                    Button {
                        jump(to: entry)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L(dynamic: entry.title))
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(SettingsTab.from(index: entry.tab)?.title ?? "")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DS.Space.s)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func jump(to entry: SettingsSearchIndex.Entry) {
        guard let tab = SettingsTab.from(index: entry.tab) else { return }
        withAnimation(.snappy(duration: 0.2)) { selectedTab = tab }
        highlightSection = entry.section.map { L(dynamic: $0) }
        highlight = L(dynamic: entry.title)
        searchText = ""
    }

    private func navigationGroup(_ title: String, tabs: [SettingsTab]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, DS.Space.s)
                .padding(.bottom, 2)

            ForEach(tabs) { tab in
                let isSelected = selectedTab == tab
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selectedTab = tab }
                } label: {
                    HStack(spacing: DS.Space.m) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(isSelected ? DS.Ink.accent : .secondary)
                            .frame(width: 20)
                        Text(tab.title)
                            .font(.system(size: 14, weight: isSelected ? .semibold : .regular, design: .rounded))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DS.Space.s)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected ? DS.Accent.brand.opacity(0.14) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-tab-\(tab.rawValue)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    // MARK: Inhalt mit großem Kopf

    private var content: some View {
        ScrollViewReader { proxy in
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                pageHeader
                selectedTabContent
                    .environment(\.settingsHighlight, highlight)
                    .environment(\.settingsHighlightSection, highlightSection)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, DS.Space.xxl)
            .padding(.top, 34)
            .padding(.bottom, DS.Space.xxl)
            .frame(maxWidth: .infinity)
            .background(DiscreetScrollers())
        }
        .scrollContentBackground(.hidden)
        .onChange(of: highlight) { _, target in
            guard let target else { return }
            // Erst nach dem Tab-Wechsel bzw. Aufklappen scrollen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo("setting-" + target, anchor: .center) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
                if highlight == target { highlight = nil; highlightSection = nil }
            }
        }
        }
        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: DS.Space.l) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DS.Accent.brandGradient)
                .frame(width: 58, height: 58)
                .overlay(
                    Image(systemName: selectedTab.icon)
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .shadow(color: DS.Accent.brand.opacity(0.28), radius: 10, y: 4)

            VStack(alignment: .leading, spacing: 3) {
                Text(selectedTab.title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text(selectedTab.navigationSubtitle)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: DS.Space.m)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isHelpModeActive.toggle() }
            } label: {
                Image(systemName: isHelpModeActive ? "info.circle.fill" : "info.circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isHelpModeActive ? DS.Ink.accent : .secondary)
                    .frame(width: 32, height: 32)
                    .glassSurface(Circle())
            }
            .buttonStyle(.plain)
            .help(L("Info-Modus: Erklärungen zu jeder Einstellung beim Überfahren"))
            .accessibilityLabel(isHelpModeActive ? L("Info-Modus ausschalten") : L("Info-Modus einschalten"))
        }
        .padding(.bottom, DS.Space.xs)
    }

    @ViewBuilder
    private var selectedTabContent: some View {
        switch selectedTab {
        case .endpoints: EndpointsTabView(viewModel: viewModel)
        case .model: ModelTabView(viewModel: viewModel)
        case .models: ModelsTabView(viewModel: viewModel)
        case .learning: LearningModeTabView(viewModel: viewModel)
        case .search: SearchTabView(viewModel: viewModel)
        case .hotkeys: HotkeysTabView(viewModel: viewModel)
        case .tools: ToolsTabView(viewModel: viewModel)
        case .advanced: AdvancedTabView(viewModel: viewModel)
        case .appearance: AppearanceTabView(viewModel: viewModel)
        }
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
                Text(L("Hilfe-Modus aktiviert"))
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                Text(L("Bewege den Mauszeiger über eine Einstellung, um ihre Erklärung zu sehen. Bedienelemente mit Erklärung sind in diesem Modus gesperrt, damit du nichts versehentlich änderst."))
                    .multilineTextAlignment(.center)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(L("Verstanden")) {
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
    case models = "Models"
    case learning = "Learning"
    case search = "Search"
    case hotkeys = "Hotkeys"
    case tools = "Tools"
    case advanced = "Advanced"
    case appearance = "Appearance"

    var id: String { rawValue }

    /// Reiter aus dem Suchindex („endpoints“, „model“ …).
    static func from(index name: String) -> SettingsTab? {
        allCases.first { $0.rawValue.lowercased() == name.lowercased() }
    }

    var title: String {
        switch self {
        case .endpoints: L("Endpunkte")
        case .model: L("Modell & KI")
        case .models: L("Modelle")
        case .learning: L("Lernmodus")
        case .search: L("Recherche")
        case .hotkeys: L("Hotkeys")
        case .tools: L("Tools")
        case .advanced: L("Erweitert")
        case .appearance: L("Darstellung")
        }
    }

    var icon: String {
        switch self {
        case .endpoints: "network"
        case .model: "cpu"
        case .models: "cube"
        case .learning: "brain"
        case .search: "magnifyingglass"
        case .hotkeys: "keyboard"
        case .tools: "wrench.and.screwdriver"
        case .advanced: "gearshape.2"
        case .appearance: "paintpalette"
        }
    }

    var tint: Color {
        switch self {
        case .endpoints: DS.Accent.blue
        case .model: DS.Accent.indigo
        case .models: DS.Accent.indigo
        case .learning: DS.Accent.amber
        case .search: DS.Accent.cyan
        case .hotkeys: DS.Accent.rose
        case .tools: DS.Accent.emerald
        case .advanced: DS.Accent.indigo
        case .appearance: DS.Accent.cyan
        }
    }

    var navigationSubtitle: String {
        switch self {
        case .endpoints: L("Server-Verbindungen, Profile und direkte Modellwahl")
        case .model: L("Modell-Parameter, Kontextfenster und Hintergrund-Jobs")
        case .models: L("Einstellungen pro Modell: Denken, Denkstärke, Sampling und Sonderschalter")
        case .learning: L("Didaktik, Lernstil und Antwortverhalten")
        case .search: L("Websuche, Quellen und lokales Browsing")
        case .hotkeys: L("Globale Tastenkürzel für schnellen Zugriff")
        case .tools: L("Werkzeuge, System-Integration und Berechtigungen")
        case .advanced: L("Hintergrund-Verarbeitung und Diagnose")
        case .appearance: L("Hell oder dunkel, Akzentfarbe, Glas, Farbfeld und Bewegung")
        }
    }
}


/// Versionsanzeige aus dem App-Bundle (MARKETING_VERSION + Build).
enum AppVersion {
    static var display: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return L("LernAssist \(version) (\(build))")
    }
}
