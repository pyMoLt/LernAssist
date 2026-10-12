import SwiftUI
import AppKit
import Carbon

// MARK: - HotkeysTabView

struct HotkeysTabView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            settingsSection(icon: "keyboard", title: "Tastenkombinationen") {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text("Drücke auf ein Feld und halte danach die gewünschte Tastenkombination gedrückt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(HotkeyAction.allCases) { action in
                        Divider()
                        HotkeyRow(action: action, viewModel: viewModel)
                    }
                }
            }

            Button("Alle zurücksetzen", role: .destructive) {
                for action in HotkeyAction.allCases {
                    if let def = Hotkey.defaultMap[action] {
                        viewModel.updateHotkey(def, for: action)
                    }
                }
            }
        }
    }
}

// MARK: - Einzelne Zeile

private struct HotkeyRow: View {
    let action: HotkeyAction
    @ObservedObject var viewModel: ChatViewModel

    /// Name einer ANDEREN Aktion mit identischem Hotkey, falls vorhanden. GlobalHotkeyManager
    /// verwirft eine solche Kollision beim Registrieren still (nur eine Aktion "gewinnt") – vorher
    /// gab es dafür keinerlei sichtbaren Hinweis in der UI, obwohl settings.json beide Werte klaglos
    /// speichert und es so aussieht, als wäre die Zuweisung erfolgreich.
    private var collidingActionName: String? {
        guard let mine = viewModel.hotkeys[action], mine.hasModifiers else { return nil }
        return HotkeyAction.allCases.first { other in
            other != action && viewModel.hotkeys[other] == mine
        }?.label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label(action.label, systemImage: action.icon)
                    .frame(width: 220, alignment: .leading)
                    .help(action.hint ?? "")

                Spacer()

                HotkeyRecorderField(
                    current: viewModel.hotkeys[action] ?? Hotkey(keyCode: -1, modifiers: 0),
                    onRecorded: { viewModel.updateHotkey($0, for: action) }
                )
            }

            if let collidingActionName {
                Text("⚠️ Kollidiert mit „\(collidingActionName)“ – nur eine der beiden Aktionen wird tatsächlich ausgelöst.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Recorder-Feld (NSViewRepresentable)

/// Ein NSTextField-Wrapper, der Tastenereignisse abfängt und als Hotkey interpretiert.
/// Kein Polling, kein Timer — einzig ein `becomeFirstResponder`-gesteuerter keyDown-Handler.
struct HotkeyRecorderField: NSViewRepresentable {
    var current: Hotkey
    var onRecorded: (Hotkey) -> Void

    func makeNSView(context: Context) -> HotkeyTextField {
        let field = HotkeyTextField()
        field.delegate = context.coordinator
        field.onRecorded = onRecorded
        field.update(hotkey: current)
        return field
    }

    func updateNSView(_ nsView: HotkeyTextField, context: Context) {
        nsView.update(hotkey: current)
        nsView.onRecorded = onRecorded
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    class Coordinator: NSObject, NSTextFieldDelegate {}
}

// MARK: - NSTextField-Subklasse

final class HotkeyTextField: NSTextField {
    var onRecorded: ((Hotkey) -> Void)?
    private var isRecording = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonSetup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonSetup()
    }

    private func commonSetup() {
        isEditable = false
        isSelectable = false
        alignment = .center
        font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        isBordered = true
        bezelStyle = .roundedBezel
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    // Klick → Aufnahme-Modus starten
    override func mouseDown(with event: NSEvent) {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        stringValue = "Taste drücken…"
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 2
        window?.makeFirstResponder(self)
        // Globale Hotkeys sind Carbon-Registrierungen, die unabhängig vom Fokus dieser Zeile
        // weiterlaufen – ohne dieses Suspendieren würde z.B. das aktuell für "Fenster
        // ein-/ausblenden" registrierte ⌘⇧L beim Versuch, GENAU DIESE Aktion neu zu belegen,
        // sofort real feuern und das Fenster (inkl. des Einstellungen-Sheets darauf)
        // verschwinden lassen, noch bevor die Aufnahme abgeschlossen werden konnte.
        GlobalHotkeyManager.shared.unregisterAll()
    }

    private func stopRecording() {
        isRecording = false
        layer?.borderWidth = 0
        // Stellt in JEDEM Fall (erfolgreiche Aufnahme, ESC-Abbruch, Fokusverlust) sicher, dass die
        // globalen Hotkeys wieder aktiv sind. Bei erfolgreicher Aufnahme hat `onRecorded` bereits
        // denselben Notification-Trigger ausgelöst – hier zusätzlich, damit ein Abbruch (der
        // `onRecorded` NICHT aufruft) die zuvor suspendierten Hotkeys nicht dauerhaft deaktiviert
        // lässt.
        NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }

        // ESC → Abbrechen
        if event.keyCode == 53 { stopRecording(); return }

        // Mindestens ⌘, ⌥ oder ⌃ nötig – reine ⇧-Kombinationen sind Großbuchstaben und
        // würden als globaler Hotkey normales Tippen in allen Apps blockieren.
        let mods = carbonModifiers(from: event.modifierFlags)
        guard mods & (Int(cmdKey) | Int(optionKey) | Int(controlKey)) != 0 else { return }

        let hk = Hotkey(keyCode: Int(event.keyCode), modifiers: mods)
        update(hotkey: hk)
        onRecorded?(hk)
        stopRecording()
    }

    /// Wandelt NSEvent.ModifierFlags in Carbon-Modifier-Maske um.
    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if flags.contains(.command) { m |= Int(cmdKey) }
        if flags.contains(.shift)   { m |= Int(shiftKey) }
        if flags.contains(.option)  { m |= Int(optionKey) }
        if flags.contains(.control) { m |= Int(controlKey) }
        return m
    }

    func update(hotkey: Hotkey) {
        if hotkey.keyCode < 0 || hotkey.modifiers == 0 {
            stringValue = "Nicht belegt"
            textColor = .secondaryLabelColor
        } else {
            stringValue = hotkey.displayString
            textColor = .labelColor
        }
    }

    // Fokus verloren → Aufnahme abbrechen
    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }
}
