import Foundation

// MARK: - Tool-Protokoll

/// Jedes Tool muss dieses Protokoll implementieren. Der `ToolRegistry` lädt nur aktive
/// Tools in den API-Payload und System-Prompt — deaktivierte verschwinden vollständig.
protocol AppTool: AnyObject {
    /// Maschinell lesbarer Name (snake_case). Muss im Function-Calling-Schema eindeutig sein.
    var name: String { get }
    /// Menschlich lesbare Beschreibung für den Settings-Tab.
    var displayName: String { get }
    /// Beschreibung im API-Schema (Few-Shot-Stil: wann nutzen, wann NICHT nutzen).
    var description: String { get }
    /// JSON-Schema für die Parameter.
    var parameters: [String: Any] { get }
    /// Ob dieses Tool aktuell aktiv ist (aus Settings).
    var isEnabled: Bool { get set }
    /// Führt das Tool aus. Gibt ein lesbares Ergebnis zurück (nie werfen, stattdessen Fehlermeldung).
    func run(arguments: String, sessionID: String?) async -> ToolResult
}

// MARK: - Tool-Ergebnis

/// Ein für den Nutzer direkt darstellbares Artefakt (Bild, interaktives HTML), das die App
/// SELBST als eigene Chat-Nachricht einfügt – unabhängig davon, ob das Modell es in seiner
/// Textantwort erwähnt oder wiederholt. Bewusst getrennt von `ToolResult.content` (das geht nur
/// als Text an das Modell zurück; ein Base64-Bild dort würde bei jeder Folgeanfrage erneut
/// den Kontext füllen).
enum ToolArtifact {
    case image(base64: String)
    case html(String)
    /// Interaktive Abfragekarte im Chat. Nach einer Karte wartet die App auf die Antwort des
    /// Nutzers, statt das Modell weiterschreiben zu lassen.
    case quiz(QuizCard)
    /// Bild NUR für das Modell (z. B. ein erneut abgerufener Screenshot) – wird nach den
    /// Tool-Ergebnissen als Bildnachricht in den nächsten Request gelegt, nicht neu angezeigt.
    case modelImage(base64: String, caption: String)
}

/// Klassifikation eines Tool-Fehlers für den App-seitigen Retry-Layer (Nutzer-Feature):
/// `.transient` = vorübergehend (Rate-Limit 429/403, 5xx, Timeout, Verbindungsfehler) – die App
/// wiederholt den Aufruf automatisch mit Jitter-Backoff, bevor das Ergebnis ans Modell geht.
/// `.fatal` = dauerhaft (Argumentfehler, blockiertes Scheme, Konfigurationsproblem) – direkt
/// zurück, das Modell muss selbst korrigieren.
enum ToolErrorKind {
    case transient
    case fatal

    /// Standard-Klassifikation anhand der Fehlerdomäne. Spezialfälle (z.B. SearXNG-403 =
    /// deaktivierte JSON-API statt Rate-Limit) klassifiziert das jeweilige Tool selbst.
    static func classify(_ error: Error) -> ToolErrorKind {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet:
                return .transient
            default:
                return .fatal
            }
        }
        if let searchError = error as? SearchService.SearchError,
           case .httpError(let code) = searchError {
            return (code == 429 || (500...599).contains(code)) ? .transient : .fatal
        }

        // WebContentService verwendet NSError, damit HTTP-Status und Parserdiagnosen auch aus
        // WebKit-/URLSession-Fallbacks bis zum Tool gelangen. 5xx/429 sowie der eigene WebKit-
        // Timeout sind vorübergehend; ungültige URL/Scheme-/Content-Argumente bleiben fatal.
        let nsError = error as NSError
        if nsError.domain == "WebContentService" {
            if nsError.code == 429 || (500...599).contains(nsError.code) || nsError.code == -2 {
                return .transient
            }
            return .fatal
        }
        if nsError.domain == "WebScraper" && nsError.code == -2 {
            return .transient
        }
        if let searchError = error as? SearchService.SearchError,
           case .parseError = searchError {
            // Eine kaputte/halb gelieferte JSON-Antwort kann beim nächsten Versuch vollständig
            // sein; ein leeres Ergebnis dagegen ist eine fachliche Antwort und kein Retry-Fall.
            return .transient
        }
        return .fatal
    }
}

struct ToolResult {
    let content: String
    /// Ein Fehler wird als Tool-Ergebnis an das Modell zurückgegeben, damit es seinen Aufruf
    /// im nächsten Turn korrigieren kann. Er ist kein Transportfehler der Unterhaltung.
    let isError: Bool
    /// Nur bei `isError` relevant: steuert, ob die App vor der Rückgabe an das Modell
    /// automatisch wiederholt (siehe ToolRegistry.execute).
    let errorKind: ToolErrorKind?
    /// Bei einem erschöpften transienten Retry bewusst false: Das Modell soll den faktischen
    /// Status sehen, aber keine dauerhaft wirkende „wiederhole/korrigiere“-Anweisung erhalten.
    let includesCorrectionGuidance: Bool
    /// Optionaler Quellenhinweis (URL, Seitenname), der in der Antwort zitiert werden soll.
    let source: String?
    /// Direkt im Chat darzustellende Artefakte (siehe `ToolArtifact`).
    let artifacts: [ToolArtifact]

    init(content: String, isError: Bool = false, errorKind: ToolErrorKind? = nil,
         source: String? = nil, artifacts: [ToolArtifact] = [],
         includesCorrectionGuidance: Bool = true) {
        self.content = content
        self.isError = isError
        self.errorKind = errorKind
        self.includesCorrectionGuidance = includesCorrectionGuidance
        self.source = source
        self.artifacts = artifacts
    }

    static func failure(_ content: String, kind: ToolErrorKind = .fatal) -> ToolResult {
        ToolResult(content: content, isError: true, errorKind: kind)
    }

    /// Formatiertes Ergebnis mit optionalem Quellenhinweis.
    var formatted: String {
        var output = content
        if let src = source, !src.isEmpty {
            output += "\n\n[Quelle: \(src)]"
        }
        guard isError else { return output }
        let correction = includesCorrectionGuidance
            ? "\n\nDer Tool-Aufruf ist fehlgeschlagen. Lies die Fehlermeldung, korrigiere die Argumente oder wähle ein passendes anderes Tool und rufe es erneut auf. Erfinde kein Ergebnis und wiederhole denselben fehlerhaften Aufruf nicht unverändert."
            : ""
        return "<TOOL_ERROR>\n\(output)\n</TOOL_ERROR>\(correction)"
    }
}

// MARK: - API-Schema (OpenAI Function-Format)

extension AppTool {
    /// Erzeugt das OpenAI-kompatible Function-Schema für den Payload.
    var openAISchema: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parameters
            ] as [String: Any]
        ]
    }
}
