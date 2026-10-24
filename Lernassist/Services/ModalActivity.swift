import Foundation

/// Merkt sich, ob gerade ein modaler Dialog (NSAlert, Sichern-Dialog) offen ist. Solange einer
/// wartet, blockiert AppKit den Main-Thread absichtlich – der Hang-Wächter soll das nicht als
/// Hänger melden (Audit 23.10.: Freigabe-Dialog für Python löste `sample` aus).
nonisolated enum ModalActivity {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var openDialogs = 0

    static var isActive: Bool { lock.withLock { openDialogs > 0 } }

    /// Führt einen modalen Dialog aus und meldet ihn für die Dauer beim Hang-Wächter ab.
    @MainActor
    static func run<T>(_ dialog: () -> T) -> T {
        lock.withLock { openDialogs += 1 }
        defer { lock.withLock { openDialogs -= 1 } }
        return dialog()
    }
}
