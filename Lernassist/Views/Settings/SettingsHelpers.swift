import SwiftUI

// MARK: - Gemeinsame Layout-Helfer für alle Settings-Tabs

@ViewBuilder
func settingsSection<Content: View, Trailing: View>(
    icon: String,
    title: String,
    @ViewBuilder trailing: () -> Trailing,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: DS.Space.s) {
        HStack(spacing: DS.Space.s) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
            Spacer()
            trailing()
        }
        AppCard {
            content()
        }
    }
}

@ViewBuilder
func settingsSection<Content: View>(icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
    settingsSection(icon: icon, title: title, trailing: { EmptyView() }, content: content)
}

@ViewBuilder
func labeledField<Content: View>(_ label: String, isModified: Bool = false, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        Text(label)
            .font(.caption2)
            .fontWeight(isModified ? .bold : .regular)
            .foregroundColor(isModified ? .primary : .secondary)
        content()
    }
}
