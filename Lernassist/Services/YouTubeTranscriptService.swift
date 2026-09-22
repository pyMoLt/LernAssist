import Foundation
import os

// MARK: - YouTubeTranscriptService (Phase H)
//
// Lädt das Untertitel-Transkript eines YouTube-Videos – nur YouTube-eigene Endpunkte, keine
// Drittanbieter-API, kein Cloud-KI-Dienst.
//
// Wichtig (Design-Entscheidung nach Verifikation gegen echte Videos): Der naive Weg über die
// Watch-Page liefert seit YouTubes "Proof-of-Origin"-Erzwingung nur noch LEERE timedtext-
// Antworten. Der zuverlässige Weg ist die interne InnerTube-Player-API mit dem ANDROID-Client:
// Sie liefert Titel + Untertitel-Spuren inkl. direkt abrufbarer URLs und wird von den gängigen
// Open-Source-Tools genauso genutzt.
//
// `nonisolated`, damit die Netzwerk-/Parsing-Arbeit nicht auf den Main-Actor gezogen wird
// (Projekt-Default-Isolation ist MainActor).

nonisolated final class YouTubeTranscriptService {
    static let shared = YouTubeTranscriptService()
    private init() {}

    /// InnerTube-API-Key des öffentlichen ANDROID-Clients (konstant, von YouTube publiziert).
    private static let innerTubeURL = URL(string: "https://www.youtube.com/youtubei/v1/player?key=AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w&prettyPrint=false")!
    private static let androidUserAgent = "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip"

    /// Lädt Titel und Untertitel-Transkript eines Videos. Bevorzugt deutsche Untertitel
    /// (korrekte Spuren vor automatischen ASR-Spuren), sonst die erste verfügbare Spur.
    /// `preferredLanguage`: BCP-47-Kurzcode (z.B. "de"), Leerstring = erste verfügbare Spur.
    /// Konfigurierbar unter Einstellungen → Erweitert (Settings-Audit).
    func fetchTranscript(from url: URL, preferredLanguage: String = "de") async throws -> (title: String, transcript: String) {
        // L1 (Perf-Audit): http UND https akzeptieren – vorher warf ein http-Link die
        // irreführende Meldung "Ungültige YouTube-URL", obwohl die URL valide war.
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https",
              let videoID = Self.videoID(from: url) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Ungültige YouTube-URL"])
        }

        // 1. InnerTube-Player-API fragen (ANDROID-Client) – Titel + Untertitel-Spuren.
        let payload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "ANDROID",
                    "clientVersion": "20.10.38",
                    "androidSdkVersion": 30,
                    "hl": "de",
                    "gl": "DE",
                ]
            ],
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        var request = URLRequest(url: Self.innerTubeURL, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.androidUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Video-Info konnte nicht geladen werden (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))"])
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Player-Antwort konnte nicht geparst werden"])
        }

        let title = (json["videoDetails"] as? [String: Any])?["title"] as? String ?? "YouTube-Video"
        guard let trackURL = Self.bestTrack(in: json, preferredLanguage: preferredLanguage) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Für dieses Video sind keine Untertitel verfügbar."])
        }

        // 2. Untertitel-Spur abrufen (SRV3-XML-Format).
        var trackRequest = URLRequest(url: trackURL, timeoutInterval: 20)
        trackRequest.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (trackData, trackResponse) = try await URLSession.shared.data(for: trackRequest)
        guard let tHTTP = trackResponse as? HTTPURLResponse, tHTTP.statusCode == 200,
              let xml = String(data: trackData, encoding: .utf8) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Untertitel konnten nicht geladen werden"])
        }

        let transcript = Self.parseSRV3XML(xml)
        guard !transcript.isEmpty else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Untertitel-Datei enthielt keinen Text"])
        }
        return (title, transcript)
    }

    // MARK: - Parsing

    /// Extrahiert die Video-ID aus watch/shorts/embed/live/youtu.be-URLs. Trailing Satzzeichen
    /// (z.B. ein Punkt am Satzende, wenn der Link aus Fließtext kopiert wurde) werden entfernt
    /// (Perf-Audit L1).
    static func videoID(from url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        guard host.hasSuffix("youtube.com") || host.hasSuffix("youtu.be") else { return nil }
        func cleaned(_ raw: String?) -> String? {
            guard var id = raw, !id.isEmpty else { return nil }
            while let last = id.last, ".!?()»«“„".contains(last) {
                id.removeLast()
            }
            return id.isEmpty ? nil : id
        }
        if host.hasSuffix("youtu.be") {
            return cleaned(url.pathComponents.dropFirst().first)
        }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value {
            return cleaned(v)
        }
        // /shorts/<id>, /embed/<id>, /live/<id>
        if url.pathComponents.count >= 3,
           ["shorts", "embed", "live"].contains(url.pathComponents[1]) {
            return cleaned(url.pathComponents[2])
        }
        return nil
    }

    /// Wählt aus der InnerTube-Antwort die beste Untertitel-Spur: bevorzugt `preferredLanguage`
    /// als korrekte Spur (ohne ASR-"kind"), dann ASR-Spur in der Sprache, sonst die erste Spur.
    static func bestTrack(in playerResponse: [String: Any], preferredLanguage: String) -> URL? {
        let captions = ((playerResponse["captions"] as? [String: Any])?["playerCaptionsTracklistRenderer"] as? [String: Any])?["captionTracks"] as? [[String: Any]] ?? []
        let entries = captions.compactMap { track -> (language: String, isASR: Bool, url: String)? in
            guard let urlString = track["baseUrl"] as? String else { return nil }
            return (track["languageCode"] as? String ?? "",
                    (track["kind"] as? String) == "asr",
                    urlString)
        }
        guard !entries.isEmpty else { return nil }

        // Leere Sprachpräferenz (Einstellung "erste verfügbare Spur"): direkt die erste Spur.
        guard !preferredLanguage.isEmpty else { return URL(string: entries[0].url) }

        let preferred = entries.filter { $0.language.hasPrefix(preferredLanguage) }
        let candidate = preferred.first { !$0.isASR } ?? preferred.first ?? entries.first
        guard let best = candidate else { return nil }
        return URL(string: best.url)
    }

    /// Parst das SRV3-XML (`<p t="..." d="...">Zeile</p>`), entfernt innere Tags und dekodiert
    /// die gängigsten Entities.
    static func parseSRV3XML(_ xml: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"<p[^>]*>(.*?)</p>"#, options: [.dotMatchesLineSeparators]) else {
            return ""
        }
        var lines: [String] = []
        regex.enumerateMatches(in: xml, range: NSRange(xml.startIndex..., in: xml)) { match, _, _ in
            guard let match, let range = Range(match.range(at: 1), in: xml) else { return }
            lines.append(Self.cleanSRV3Text(String(xml[range])))
        }
        return lines.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func cleanSRV3Text(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
        let entities: [String: String] = [
            "&amp;": "&", "&#39;": "'", "&quot;": "\"",
            "&#160;": " ", "&lt;": "<", "&gt;": ">", "&apos;": "'",
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
