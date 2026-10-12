import Foundation
import SwiftUI
import AppKit
import Combine
import os

// Bildkontext-Einfrieren, Thinking-Hilfen und Kontext-Budget.
extension ChatViewModel {
    // MARK: - Hilfsmethoden

    /// Friert für alle Nachrichten außer `excludedId` (der neuen, gerade hervorgehobenen
    /// Nachricht) den Bildkontext einmalig ein – siehe `ChatMessage.frozenImageContext`.
    /// Läuft synchron auf dem Main-Actor, direkt bevor eine neue Anfrage aufgebaut wird.
    func freezeImageContextForOlderMessages(sessionIdx: Int, excluding excludedId: UUID) {
        guard !keepMultipleImagesInHistory else { return } // dort werden Bilder ohnehin immer roh mitgeschickt
        for i in sessions[sessionIdx].messages.indices {
            let msg = sessions[sessionIdx].messages[i]
            guard msg.role == "user", msg.id != excludedId, msg.imageBase64 != nil || msg.imageID != nil,
                  !msg.isImageContextFrozen else { continue }
            sessions[sessionIdx].messages[i].frozenImageContext = msg.imageDescription
            sessions[sessionIdx].messages[i].isImageContextFrozen = true
        }
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
    static func trimmedToContextBudget(_ messages: [[String: Any]], contextWindow: Int?, maxTokens: Int?) -> [[String: Any]] {
        // 75 % des Fensters als Prompt-Budget, der Rest als Reserve für die Antwort.
        let window = max(contextWindow ?? 8192, 2048)
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

        var remaining = total(messages)
        var removeUntil = 0
        for segment in segments where segment.upperBound <= protectedStart {
            if remaining <= budget { break }
            for idx in segment {
                remaining -= estimatedTokens(of: messages[idx])
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
