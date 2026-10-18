import SwiftUI
import ApplicationServices
import CoreGraphics

// MARK: - Berechtigungs-Assistent (erster App-Start)
//
// Zeigt beim allerersten Start ein kleines Fenster mit allen Berechtigungen, die LernAssist
// braucht – mit Live-Status und direktem Anforderungs-Button. Bewusst NUR die zwei
// Berechtigungen, die die App tatsächlich verwendet (Zugriffs-Hilfen für „Auswahl erklären“,
// Bildschirmaufnahme für Screenshots): Kein Anfordern von Rechten, die nicht gebraucht
// werden (z.B. Input Monitoring – die App liest keine Tastatur, die globalen Hotkeys laufen
// über Carbon ohne diese Berechtigung).

// MARK: - Berechtigungs-Definitionen

struct AppPermission: Identifiable {
    let id: String
    let title: String
    let featureDescription: String
    let icon: String
    let isGranted: () -> Bool
    /// Fordert die Berechtigung an: öffnet den nativen System-Dialog bzw. die passende
    /// Systemeinstellung mit vorbereiteter App-Auswahl.
    let request: () -> Void
}

enum AppPermissions {
    static let accessibility = AppPermission(
        id: "accessibility",
        title: "Zugriffs-Hilfen",
        featureDescription: "Für „Auswahl erklären“ (⌘⌥E): liest die markierte Textauswahl aus beliebigen anderen Apps. Greift sofort nach Erteilung.",
        icon: "text.magnifyingglass",
        isGranted: { AXIsProcessTrusted() },
        request: {
            // Nativer System-Prompt: öffnet die Zugriffs-Hilfen-Einstellungen mit
            // vorbereiteter App-Auswahl (LernAssist ist zum Aktivieren markiert).
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        })

    static let screenRecording = AppPermission(
        id: "screenRecording",
        title: "Bildschirmaufnahme",
        featureDescription: "Für Screenshots (Screenshot-Hotkey, „Was ist auf diesem Screenshot zu sehen?“). Greift ggf. erst nach einem App-Neustart.",
        icon: "camera.viewfinder",
        isGranted: { CGPreflightScreenCaptureAccess() },
        request: {
            // Nativer System-Dialog zum Erteilen der Bildschirmaufnahme.
            _ = CGRequestScreenCaptureAccess()
        })

    static let all: [AppPermission] = [accessibility, screenRecording]

    static var allGranted: Bool { all.allSatisfy { $0.isGranted() } }
}

// MARK: - PermissionOnboardingView

struct PermissionOnboardingView: View {
    /// `true` = Nutzer hat mit „Fertig“ bestätigt (Fenster erscheint beim nächsten Start
    /// nicht mehr). `false` = „Später“ – Fenster kommt beim nächsten Start erneut.
    var onClose: (_ completed: Bool) -> Void

    @AppStorage("hasCompletedPermissionOnboarding") private var completed: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Kopf
            VStack(spacing: DS.Space.s) {
                LernAssistBrandIcon(size: 52)
                    .shadow(color: DS.Accent.indigo.opacity(0.24), radius: 12, y: 4)
                Text("Willkommen bei LernAssist")
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                Text("Zwei Berechtigungen schalten die komfortabelsten Funktionen frei. Du kannst sie jetzt oder später einrichten.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.Space.m)
            }
            .padding(.top, DS.Space.xl)
            .padding(.bottom, DS.Space.l)

            // Berechtigungen – Status im Sekundentakt live neu geprüft, damit das
            // Erteilen in den Systemeinstellungen sofort sichtbar wird.
            TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                VStack(spacing: DS.Space.m) {
                    ForEach(AppPermissions.all) { permission in
                        PermissionRow(permission: permission)
                    }
                }
                .padding(.vertical, DS.Space.m)
                .padding(.horizontal, DS.Space.l)
            }

            // Fuß
            VStack(spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    Button("Später nachholen") {
                        onClose(false)
                    }
                    .buttonStyle(SoftActionButtonStyle())

                    Button("Fertig") {
                        completed = true
                        onClose(true)
                    }
                    .buttonStyle(SoftActionButtonStyle(tint: DS.Accent.indigo, prominent: true))
                    .disabled(!AppPermissions.allGranted)
                }
                if !AppPermissions.allGranted {
                    Text("„Fertig“ wird aktiv, sobald beide Berechtigungen erteilt sind – oder wähle „Später“, dann meldet sich dieses Fenster in zwei Wochen wieder (jederzeit über die Einstellungen erreichbar).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DS.Space.l)
                }
            }
            .padding(.vertical, DS.Space.l)
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .background(DS.Surface.canvas)
    }
}

// MARK: - PermissionRow

struct PermissionRow: View {
    let permission: AppPermission

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: permission.icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(DS.Ink.accent.gradient)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: DS.Space.s) {
                    Text(permission.title)
                        .font(.system(.headline, design: .rounded))
                    statusBadge
                }
                Text(permission.featureDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DS.Space.s)

            if permission.isGranted() {
                Label("Erteilt", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(.vertical, DS.Space.xs)
            } else {
                Button("Berechtigen…") {
                    permission.request()
                }
                .controlSize(.large)
            }
        }
        .padding(DS.Space.m)
        .background(RoundedRectangle(cornerRadius: DS.Radius.medium).fill(DS.Surface.chip))
    }

    private var statusBadge: some View {
        Group {
            if permission.isGranted() {
                EmptyView()
            } else {
                Text("Ausstehend")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, DS.Space.xs)
                    .padding(.vertical, DS.Space.xxs)
                    .background(Capsule().fill(Color.orange.opacity(0.12)))
            }
        }
    }
}
