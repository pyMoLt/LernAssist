import Foundation
import Carbon

// MARK: - Belegbare Aktionen

/// Jede Aktion, die per globalem Hotkey ausgelöst werden kann.
enum HotkeyAction: String, CaseIterable, Codable, Identifiable {
    case toggleWindow   = "toggleWindow"
    case screenshot     = "screenshot"
    case newChat        = "newChat"
    case toggleSidebar  = "toggleSidebar"
    case explainSelection = "explainSelection"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .toggleWindow:  return L("Fenster ein-/ausblenden")
        case .screenshot:    return L("Screenshot aufnehmen")
        case .newChat:       return L("Neuer Chat")
        case .toggleSidebar: return L("Sidebar ein-/ausblenden")
        case .explainSelection: return L("Auswahl erklären (systemweit)")
        }
    }

    /// Zusätzlicher Hinweistext für die Hotkeys-Einstellungen – vor allem für `.toggleWindow`
    /// wichtig: die Aktion öffnet das Fenster bereits MIT Screenshot, wenn es verborgen ist, und
    /// blendet es nur aus, wenn es sichtbar ist. Eine eigene Belegung von `.screenshot` auf
    /// DENSELBEN Hotkey ist dafür nicht nötig (und wird von der Kollisionserkennung ohnehin
    /// verworfen) – ein einziger Hotkey auf `.toggleWindow` deckt "öffnen mit Screenshot" UND
    /// "wieder schließen" bereits ab.
    var hint: String? {
        switch self {
        case .toggleWindow: return "Öffnet das Fenster MIT Screenshot, wenn es verborgen ist – und schließt es wieder, wenn es sichtbar ist. Ein Hotkey genügt für beides."
        default: return nil
        }
    }

    var icon: String {
        switch self {
        case .toggleWindow:  return "macwindow"
        case .screenshot:    return "camera.viewfinder"
        case .newChat:       return "plus.bubble"
        case .toggleSidebar: return "sidebar.left"
        case .explainSelection: return "text.magnifyingglass"
        }
    }
}

// MARK: - Hotkey-Modell

/// Eine einzelne, gespeicherte Tastenkombination.
/// `keyCode` ist der Carbon-Key-Code (z.B. 37 = L, 35 = P).
/// `modifiers` ist eine Bitmaske aus Carbon-Modifier-Flags.
struct Hotkey: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int   // Carbon: cmdKey=0x0100, shiftKey=0x0200, optionKey=0x0800, controlKey=0x1000

    /// Human-readable Darstellung (z.B. "⌘⇧L")
    var displayString: String {
        var s = ""
        if modifiers & controlKey != 0 { s += "⌃" }
        if modifiers & optionKey  != 0 { s += "⌥" }
        if modifiers & shiftKey   != 0 { s += "⇧" }
        if modifiers & cmdKey     != 0 { s += "⌘" }
        s += Self.keyCodeToString(keyCode)
        return s
    }

    /// Gibt true zurück wenn die Kombination keine Modifier-Tasten enthält (unsicher als globaler Hotkey).
    var hasModifiers: Bool { modifiers != 0 }

    // MARK: - Defaults

    static let defaultMap: [HotkeyAction: Hotkey] = [
        .toggleWindow:  Hotkey(keyCode: 37, modifiers: Int(cmdKey) | Int(shiftKey)),  // ⌘⇧L
        // War früher identisch zu .toggleWindow (⌘⇧L): GlobalHotkeyManager registriert jede Aktion
        // als EIGENEN Carbon-Hotkey-Eintrag, auch wenn zwei Aktionen denselben Key belegen – macOS
        // feuert dann für EINEN Tastendruck zwei separate kEventHotKeyPressed-Events, d.h. beide
        // Handler liefen. Das führte dazu, dass reines Ausblenden des Fensters (.toggleWindow im
        // "verstecken"-Zweig) zusätzlich einen ungewollten interaktiven Screenshot auslöste (Cursor
        // wird zum Fadenkreuz), und Öffnen des Fensters den Screenshot doppelt auslöste. Eigener
        // Default-Key behebt die Kollision; siehe auch HotkeysTabView für Duplikat-Warnung bei
        // manueller Neubelegung.
        //
        // Globale Hotkeys gelten in ALLEN Apps. ⌘⇧S („Sichern unter“), ⌘N und ⌘J kaperten deshalb
        // Standard-Kürzel anderer Programme; „Neuer Chat“ lag zudem auf KeyCode 78 (Keypad-Minus)
        // statt N (Audit 2026-10-12). Neue Defaults nutzen ⌃⇧ – systemweit kaum belegt.
        .screenshot:    Hotkey(keyCode: 1,  modifiers: Int(controlKey) | Int(shiftKey)), // ⌃⇧S
        .newChat:       Hotkey(keyCode: 45, modifiers: Int(controlKey) | Int(shiftKey)), // ⌃⇧N
        .toggleSidebar: Hotkey(keyCode: 38, modifiers: Int(controlKey) | Int(shiftKey)), // ⌃⇧J
        // ⌥⌘E ("Explain"): Liest die aktuelle Textauswahl der AKTIVEN App und fragt das
        // Modell danach – benötigt die Zugriffs-Hilfen-Berechtigung (siehe AppDelegate).
        .explainSelection: Hotkey(keyCode: 14, modifiers: Int(cmdKey) | Int(optionKey)), // ⌘⌥E
    ]

    // MARK: - keyCode → lesbarer String

    /// Frühere Defaults, die beim Laden alter Einstellungen auf die neuen umgestellt werden –
    /// nur wenn der Nutzer sie nie geändert hat (Wert identisch mit dem alten Default).
    static let legacyDefaultMap: [HotkeyAction: Hotkey] = [
        .screenshot:    Hotkey(keyCode: 1,  modifiers: Int(cmdKey) | Int(shiftKey)),
        .newChat:       Hotkey(keyCode: 78, modifiers: Int(cmdKey)),
        .toggleSidebar: Hotkey(keyCode: 38, modifiers: Int(cmdKey)),
    ]

    static func migratedFromLegacyDefaults(_ stored: [String: Hotkey]) -> [String: Hotkey] {
        var result = stored
        for (action, legacy) in legacyDefaultMap where stored[action.rawValue] == legacy {
            result[action.rawValue] = defaultMap[action]
        }
        return result
    }

    static func keyCodeToString(_ kc: Int) -> String {
        let map: [Int: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K",
            45: "N", 46: "M",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
            25: "9", 26: "7", 28: "8", 29: "0",
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return map[kc] ?? "(\(kc))"
    }
}
