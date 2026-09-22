import Foundation
import Combine
import SwiftUI

struct SlashCommand: Identifiable {
    let id: String
    let aliases: [String]
    let description: String
    let paramHint: String?
    let action: (String) -> Void
}

/// Registry der Slash-Befehle. Bewusst KEIN Singleton mehr (Audit M13): Früher registrierte nur
/// die erste ChatViewModel-Instanz ihre Befehle mit `weak self` auf `SlashCommandRegistry.shared` –
/// nach deren Deallokation waren alle Befehle stille No-Ops, und eine zweite Instanz registrierte
/// wegen des `commands.isEmpty`-Guards gar nicht erst. Jede ChatViewModel-Instanz hält jetzt ihre
/// eigene Registry (siehe `ChatViewModel.slashCommandRegistry`).
class SlashCommandRegistry {
    var commands: [SlashCommand] = []

    init() {
        // Die Registrierung der konkreten Befehle erfolgt durch das ChatViewModel,
        // da viele Befehle den App-State brauchen.
    }
    
    func matching(prefix: String) -> [SlashCommand] {
        let cleanPrefix = prefix.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Entfernt führenden Slash falls vorhanden, um die Suche zu vereinfachen
        let search = cleanPrefix.hasPrefix("/") ? String(cleanPrefix.dropFirst()) : cleanPrefix
        
        guard !search.isEmpty else { return commands }
        
        return commands.filter { cmd in
            cmd.id.lowercased().hasPrefix(search) ||
            cmd.aliases.contains(where: { $0.lowercased().hasPrefix(search) })
        }
    }
    
    func register(command: SlashCommand) {
        commands.append(command)
    }
}
