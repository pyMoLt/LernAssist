import Foundation
import Carbon
import AppKit
import os

/// Verwaltet mehrere globale Hotkeys gleichzeitig.
/// Jede Aktion bekommt eine eigene `EventHotKeyRef`; bei Änderungen wird nur der betroffene Eintrag
/// neu registriert (Unregister → Register), nicht der ganze Handler.
///
/// **Kein Polling / keine Endlos-Berechnungen:** Das Carbon-Event-System ist callback-getrieben;
/// der `installEventHandler`-Block wird nur aufgerufen, wenn macOS einen passenden Key-Event liefert.
class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    // action → (registrierter HotKeyRef, hotKeyID)
    private var registrations: [HotkeyAction: (ref: EventHotKeyRef, id: UInt32)] = [:]
    private var nextID: UInt32 = 1

    // action → Callback (gesetzt vom AppDelegate)
    var handlers: [HotkeyAction: () -> Void] = [:]

    private init() {
        installCarbonHandler()
    }

    // MARK: - Registrierung

    // action → zuletzt registrierte Kombination (für Kollisionserkennung, siehe unten)
    private var registeredHotkeys: [HotkeyAction: Hotkey] = [:]

    /// Registriert (oder überschreibt) den Hotkey für eine Aktion.
    /// Wird mit `keyCode = -1` oder `modifiers = 0` aufgerufen → Hotkey entfernen.
    func register(action: HotkeyAction, hotkey: Hotkey) {
        unregister(action: action) // alten zuerst entfernen

        guard hotkey.keyCode >= 0, hotkey.modifiers != 0 else { return }

        // Kollisionsschutz: Registriert macOS dieselbe Tastenkombination für zwei verschiedene
        // Aktionen, feuert ein einziger Tastendruck ZWEI separate Carbon-Events (eines pro
        // Registrierung) – beide Handler liefen dann gleichzeitig für einen Tastendruck (führte
        // z.B. dazu, dass Fenster-Ausblenden ungewollt zusätzlich einen Screenshot auslöste).
        // Deshalb: die zuerst registrierte Aktion gewinnt, Kollisionen werden übersprungen.
        if let conflictingAction = registeredHotkeys.first(where: { $0.key != action && $0.value == hotkey })?.key {
            AppLog.ui.warning("Hotkeys: \(action.rawValue) → \(hotkey.displayString) kollidiert bereits mit \(conflictingAction.rawValue), Aktion übersprungen")
            return
        }
        registeredHotkeys[action] = hotkey

        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C524E41), id: id) // 'LRNA'
        var ref: EventHotKeyRef?

        let status = RegisterEventHotKey(
            UInt32(hotkey.keyCode),
            UInt32(hotkey.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            registrations[action] = (ref: ref, id: id)
            AppLog.ui.info("Hotkey registriert: \(action.rawValue) → \(hotkey.displayString)")
        } else {
            AppLog.ui.error("Hotkey-Registrierung fehlgeschlagen für \(action.rawValue) (Status \(status))")
        }
    }

    func unregister(action: HotkeyAction) {
        if let entry = registrations.removeValue(forKey: action) {
            UnregisterEventHotKey(entry.ref)
        }
        registeredHotkeys.removeValue(forKey: action)
    }

    func unregisterAll() {
        for (_, entry) in registrations { UnregisterEventHotKey(entry.ref) }
        registrations.removeAll()
        registeredHotkeys.removeAll()
    }

    // MARK: - Carbon-Event-Handler (einmalig installieren)

    private func installCarbonHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // Statische C-Closure: kein Zugriff auf `self` direkt → über shared singleton
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                var hkID = EventHotKeyID()
                let err = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hkID
                )
                guard err == noErr else { return noErr }
                GlobalHotkeyManager.shared.handleHotKeyEvent(id: hkID.id)
                return noErr
            },
            1, &eventType, nil, nil
        )
    }

    private func handleHotKeyEvent(id: UInt32) {
        // Suche die Aktion zu dieser ID
        for (action, entry) in registrations where entry.id == id {
            DispatchQueue.main.async {
                self.handlers[action]?()
            }
            return
        }
    }

    deinit { unregisterAll() }
}
