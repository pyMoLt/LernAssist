import SwiftUI

// MARK: - Environment Key
struct HelpModeActiveKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var isHelpModeActive: Bool {
        get { self[HelpModeActiveKey.self] }
        set { self[HelpModeActiveKey.self] = newValue }
    }
}

// MARK: - View Modifier
struct SettingHelpModifier: ViewModifier {
    @Environment(\.isHelpModeActive) var isHelpModeActive
    let helpText: String
    
    @State private var isHovered = false
    
    func body(content: Content) -> some View {
        content
            // Ein unsichtbares Overlay liegt über dem Element, wenn der Hilfemodus aktiv ist.
            // Das blockiert Klicks (allowsHitTesting) und fängt das Hovern ab!
            .overlay(
                Color.black.opacity(0.001)
                    .allowsHitTesting(isHelpModeActive)
                    .onHover { hovering in
                        if isHelpModeActive {
                            withAnimation(.easeInOut(duration: 0.1)) {
                                isHovered = hovering
                            }
                        } else {
                            isHovered = false
                        }
                    }
            )
            // Optisches Hervorheben, wenn Hilfe-Modus aktiv ist
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isHovered ? DS.Ink.accent : DS.Ink.accent.opacity(0.4), lineWidth: 2)
                    .padding(-4)
                    .opacity(isHelpModeActive ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: isHelpModeActive)
            )
            // Sofortiges Custom-Popover
            .popover(isPresented: $isHovered, arrowEdge: .trailing) {
                // Höhenbegrenzung (Erweitert-Tab-Hang): Der Tab enthält die mit Abstand
                // längsten Hilfetexte der App – ein Popover, das höher ist als der Bildschirm,
                // kann beim Positionieren Fenster wie App zum Stillstand bringen. ScrollView +
                // maxHeight halten jedes Hilfetext-Popover in sicheren Grenzen.
                ScrollView {
                    Text(helpText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(12)
                        .frame(width: 260, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 340)
                // Hässlichen weißen Rand in Darkmode verstecken
                .background(Color(NSColor.windowBackgroundColor))
            }
            .onChange(of: isHelpModeActive) { active in
                if !active { isHovered = false }
            }
    }
}

extension View {
    /// Hängt einen Hilfetext an das UI-Element an. Dieser wird nur als nativer Tooltip angezeigt,
    /// wenn der globale Hilfe-Modus (`isHelpModeActive`) aktiviert ist. Zudem wird das Element
    /// dann visuell leicht blau hervorgehoben.
    func settingHelp(_ text: String) -> some View {
        self.modifier(SettingHelpModifier(helpText: text))
    }
}
