import Foundation
import SwiftUI
import AppKit
import Combine
import os

// Bildkontext-Einfrieren, Thinking-Hilfen und Kontext-Budget.
extension ChatViewModel {
    // MARK: - Hilfsmethoden

    /// Wie viel Verlauf (geschätzte Tokens) hinter dem neuesten Screenshot liegen darf, bevor er
    /// in Text umgewandelt wird.
    static let imageRetentionTokenCap = 4_000

    /// Bild-Regel für den Verlauf („B mit Deckel“): Der neueste Screenshot geht als Bild mit, bis
    /// ein neuer Screenshot kommt oder mehr als `imageRetentionTokenCap` Tokens Verlauf hinter ihm
    /// liegen. Dann wird er einmalig und dauerhaft auf seine Textbeschreibung eingefroren – erst,
    /// wenn die Beschreibung fertig ist, sonst ginge der Bildinhalt verloren.
    /// Hintergrund: Jede Umwandlung ändert den Prompt ab dieser Stelle und kostet eine
    /// Neuberechnung von allem, was dahinter liegt. Der Deckel hält diese Kosten klein, und im
    /// Kontext steht höchstens ein echtes Bild. Läuft direkt vor dem Aufbau jeder neuen Anfrage.
    func applyImageRetention(sessionIdx: Int) {
        guard !keepMultipleImagesInHistory, sessions.indices.contains(sessionIdx) else { return }
        let messages = sessions[sessionIdx].messages
        func hasImage(_ msg: ChatMessage) -> Bool {
            msg.role == "user" && (msg.imageBase64 != nil || msg.imageID != nil)
        }
        guard let newest = messages.lastIndex(where: hasImage) else { return }
        for i in messages.indices where hasImage(messages[i]) && !messages[i].isImageContextFrozen {
            if i == newest {
                let behind = messages[(i + 1)...].reduce(0) { $0 + Self.estimatedHistoryTokens(of: $1) }
                if behind <= Self.imageRetentionTokenCap { continue }
            }
            // Ohne automatische Bildbeschreibung gibt es nie eine – dann wie bisher ohne Text.
            if autoImageToTextEnabled, messages[i].imageDescription == nil { continue }
            sessions[sessionIdx].messages[i].frozenImageContext = messages[i].imageDescription
            sessions[sessionIdx].messages[i].isImageContextFrozen = true
        }
    }

    /// Grobe Token-Schätzung einer gespeicherten Nachricht (Text, Thinking, Tool-Ergebnisse).
    static func estimatedHistoryTokens(of msg: ChatMessage) -> Int {
        var chars = msg.content.count + (msg.thinking?.count ?? 0)
        for call in msg.toolCalls ?? [] {
            chars += call.arguments.count + (call.result?.count ?? 0)
        }
        return chars / 4
    }

    /// Inline-Think-Tag-Paar, per Unicode-Escapes geschrieben (identisch zu den Tags im
    /// StreamingDelegate, bewusst ohne Literal im Quelltext).
    private static let thinkOpenTag = "\u{3C}think\u{3E}"
    private static let thinkCloseTag = "\u{3C}/think\u{3E}"

    /// Content-Ersatz für Assistant-Nachrichten ohne sichtbaren Text: der Denkprozess
    /// wird als Inline-Think-Block gesendet. (Fix: Vorher standen hier versehentlich
    /// verdoppelte Backslashes - das Modell erhielt den Literal-Text statt des Denkprozesses.)
    static func thinkingOnlyContent(_ thinking: String) -> String {
        thinkOpenTag + "\n" + thinking + "\n" + thinkCloseTag
    }

    // MARK: - Kontext-Budget

    /// Grobe Token-Schätzung für einen API-Payload-Eintrag (Zeichen/4 + Fixkosten pro
    /// Nachricht). Bilder werden als konservativer Pauschalwert angesetzt, da die echten
    /// visuellen Token server- und auflösungsabhängig sind. Für das Budget-Trimmen reicht
    /// eine grobe, aber deterministische Schätzung vollständig aus.
    static func estimatedTokens(of message: [String: Any]) -> Int {
        let content: Any = message["content"] ?? NSNull()
        var chars = 0
        var images = 0
        if let s = content as? String {
            chars = s.count
        } else if let parts = content as? [[String: Any]] {
            for part in parts {
                if let t = part["text"] as? String { chars += t.count }
                if part["image_url"] != nil { images += 1 }
            }
        }
        if let imagesField = message["images"] as? [String] { images += imagesField.count }
        // Mitgesendetes Thinking (Preserve Thinking) belegt ebenfalls Kontext.
        if let reasoning = message["reasoning_content"] as? String { chars += reasoning.count }
        // Ollama liefert Bilder als flaches base64-Array statt als content-Teile.
        return chars / 4 + images * 2500 + 16
    }

    /// Kürzt den Payload deterministisch auf das geschätzte Kontextbudget, damit lange Chats
    /// (inkl. Volltext-Dokumenten-Anhängen) nicht irgendwann mit HTTP 400 vom Server abgewiesen
    /// werden. Entfernt die ältesten Runden als ganze Segmente (User-/Assistant-Nachricht inkl.
    /// ihrer tool-Resultate, damit kein Tool-Call ohne Ergebnis verwaist und der Server die
    /// Folge-Anfrage mit 400 ablehnt). System-Nachricht (Index 0) und die letzte Runde bleiben
    /// immer erhalten. Deterministisch, damit der Prompt-Präfix bei unverändertem Verlauf
    /// stabil bleibt und der serverseitige KV-Cache nicht unnötig invalidiert wird.
    static let fallbackContextWindow = 32_768

    static func trimmedToContextBudget(_ messages: [[String: Any]], contextWindow: Int?, maxTokens: Int?) -> [[String: Any]] {
        // 75 % des Fensters als Prompt-Budget, der Rest als Reserve für die Antwort. Ohne
        // bekannte Fenstergröße 32k (oMLX-Standard) statt 8k: Mit 8k schnitt die App bei Profilen
        // ohne gemeldete Größe schon ab ~7k Tokens bei jeder Anfrage den Verlaufsanfang ab.
        let window = max(contextWindow ?? Self.fallbackContextWindow, 2048)
        let reserve = min(maxTokens ?? 1024, window / 4)
        let budget = max(window - reserve, window / 2)

        func total(_ msgs: [[String: Any]]) -> Int {
            msgs.reduce(0) { $0 + estimatedTokens(of: $1) }
        }
        guard total(messages) > budget, messages.count > 2 else { return messages }

        // Segmente ab Index 1 bilden: Ein Segment beginnt mit einer Nicht-tool-Nachricht und
        // schließt direkt folgende tool-Ergebnisse mit ein.
        var segments: [Range<Int>] = []
        var start = 1
        var i = 1
        while i < messages.count {
            if let role = messages[i]["role"] as? String, role == "tool" {
                i += 1
                continue
            }
            if i > start { segments.append(start..<i) }
            start = i
            i += 1
        }
        segments.append(start..<messages.count)

        // Geschützt ist alles ab der LETZTEN User-Nachricht: In Tool-Runden ist das letzte
        // Segment nur der Tool-Block – früher fiel dadurch genau die aktuelle Frage weg
        // (Audit 2026-10-12, Chat-Kern H3).
        let lastUserIndex = messages.lastIndex(where: { ($0["role"] as? String) == "user" }) ?? messages.count - 1
        let protectedStart = max(1, min(lastUserIndex, segments.last?.lowerBound ?? lastUserIndex))

        // In Blöcken kürzen statt jedes Mal knapp unter das Budget: Würde die Schnittstelle mit
        // jeder neuen Nachricht ein Stück wandern, wäre der Prompt-Anfang bei jeder Anfrage anders
        // und der Server müsste alles neu berechnen. So bleibt der Schnitt stehen, bis wieder ein
        // ganzer Block (30 % des Budgets) dazugekommen ist.
        let chunk = max(budget * 3 / 10, 1)
        let overflow = total(messages) - budget
        let toRemove = ((overflow + chunk - 1) / chunk) * chunk
        var removed = 0
        var removeUntil = 0
        for segment in segments where segment.upperBound <= protectedStart {
            if removed >= toRemove { break }
            for idx in segment {
                removed += estimatedTokens(of: messages[idx])
            }
            removeUntil = segment.upperBound
        }
        guard removeUntil > 0 else { return messages }

        // System-Prompt (Index 0) bleibt erhalten – früher wurde er mit den alten Runden
        // abgeschnitten, weil der Slice erst NACH ihm begann.
        var trimmed: [[String: Any]] = []
        // Der Hinweis wird an den System-Prompt angehängt statt als zweite system-Nachricht:
        // Qwen-Templates lehnen system-Nachrichten außerhalb von Index 0 ab.
        if var system = messages.first, (system["role"] as? String) == "system" {
            let base = system["content"] as? String ?? ""
            system["content"] = base + "\n\n[Hinweis: Ältere Nachrichten wurden zur Einhaltung des Kontextfensters ausgelassen.]"
            trimmed.append(system)
        }
        trimmed.append(contentsOf: messages[removeUntil...])
        return trimmed
    }
}
