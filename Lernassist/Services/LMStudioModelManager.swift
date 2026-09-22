import Foundation
import os

// MARK: - LMStudioStatus (für UI-Badge)

/// Zustand der LM Studio Verbindung und des Modell-Ladens – wird in der Chat-View als Badge angezeigt.
enum LMStudioStatus: Equatable {
    case idle                     // Noch nichts versucht / kein LM Studio Profil aktiv
    case loading(String)          // Modell wird gerade geladen (Modell-ID als String)
    case loaded                   // Modell erfolgreich geladen, bereit
    case unreachable              // LM Studio nicht erreichbar (nicht gestartet)

    var label: String {
        switch self {
        case .idle:               return ""
        case .loading(let m):    return "Lade \(m.split(separator: "/").last.map(String.init) ?? m)…"
        case .loaded:             return "Modell bereit"
        case .unreachable:        return "LM Studio nicht erreichbar"
        }
    }

    var systemImage: String {
        switch self {
        case .idle:               return ""
        case .loading:            return "arrow.trianglehead.2.clockwise"
        case .loaded:             return "checkmark.circle.fill"
        case .unreachable:        return "exclamationmark.triangle.fill"
        }
    }

    var color: String {  // SwiftUI Color name
        switch self {
        case .idle:               return "clear"
        case .loading:            return "orange"
        case .loaded:             return "green"
        case .unreachable:        return "red"
        }
    }
}

// MARK: - LMStudioModelManager
//
// Verwaltet das automatische Laden und Entladen von Modellen über die
// LM Studio Native REST API v1 (POST /api/v1/models/load, /api/v1/models/unload).
//
// Nur relevant wenn der Endpunkt ein lokales LM Studio ist.
// Für alle anderen Provider (OpenAI, Ollama, Groq, …) ist dieser Manager inaktiv.

actor LMStudioModelManager {
    static let shared = LMStudioModelManager()
    
    // MARK: - Zustand
    
    /// Derzeit geladene Modelle: modelId → instanceId
    private var loadedModels: [String: String] = [:]
    
    /// Referenz-Zähler: instanceId → Anzahl aktiver Aufgaben
    private var refCounts: [String: Int] = [:]
    
    /// Idle-Timer Tasks: instanceId → laufender Task der nach 3s entlädt
    private var idleTimers: [String: Task<Void, Never>] = [:]
    
    /// Aktuell laufende Lade-Vorgänge: modelId → Task
    private var inProgressLoads: [String: Task<String?, Never>] = [:]
    
    // MARK: - Public API
    
    /// Stellt sicher, dass das Modell geladen ist. Gibt die instanceId zurück.
    /// Prüft in dieser Reihenfolge:
    /// 1. In-Memory-Cache (schnell, kein Netzwerk)
    /// 2. Server-Abfrage (GET /api/v1/models) — erkennt Modelle die schon in LM Studio laufen
    /// 3. Laden via POST /api/v1/models/load (nur wenn wirklich nicht geladen)
    @discardableResult
    func acquire(modelId: String, baseURL: String, apiKey: String) async -> String? {
        // 1. In-Memory-Cache: Idle-Timer abbrechen falls wir gerade am Entladen sind
        if let instanceId = loadedModels[modelId] {
            idleTimers[instanceId]?.cancel()
            idleTimers[instanceId] = nil
            refCounts[instanceId, default: 0] += 1
            AppLog.services.info("LMStudioModelManager: '\(modelId)' aus Cache → instanceId: \(instanceId)")
            return instanceId
        }
        
        // 2. Lade-Vorgang läuft bereits für dieses Modell? (Verhindert doppelte POSTs bei Nebenläufigkeit)
        if let task = inProgressLoads[modelId] {
            if let instanceId = await task.value {
                refCounts[instanceId, default: 0] += 1
                return instanceId
            }
            // Falls Task fehlschlug, normal weiterversuchen
        }
        
        let loadTask = Task<String?, Never> {
            // 3. Server fragen — vielleicht ist das Modell schon geladen
            if let existingId = await self.checkAlreadyLoaded(modelId: modelId, baseURL: baseURL, apiKey: apiKey) {
                AppLog.services.info("LMStudioModelManager: '\(modelId)' schon geladen auf Server → instanceId: \(existingId)")
                return existingId
            }
            // 4. Modell ist wirklich nicht geladen → jetzt erst laden
            return await self.loadModel(modelId: modelId, baseURL: baseURL, apiKey: apiKey)
        }
        
        inProgressLoads[modelId] = loadTask
        let instanceId = await loadTask.value
        inProgressLoads.removeValue(forKey: modelId)
        
        guard let validId = instanceId else { return nil }
        loadedModels[modelId] = validId
        refCounts[validId, default: 0] += 1
        return validId
    }

    
    /// Gibt die Ressource frei. Nach 3s Leerlauf wird das Modell automatisch entladen.
    func release(instanceId: String, modelId: String, baseURL: String, apiKey: String) {
        refCounts[instanceId, default: 1] -= 1
        guard refCounts[instanceId, default: 0] <= 0 else { return }
        refCounts[instanceId] = 0
        
        // 3-Sekunden-Idle-Timer starten
        idleTimers[instanceId]?.cancel()
        let timer = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await self.unloadIfIdle(instanceId: instanceId, modelId: modelId, baseURL: baseURL, apiKey: apiKey)
        }
        idleTimers[instanceId] = timer
    }
    
    // MARK: - Private Helpers
    
    private func unloadIfIdle(instanceId: String, modelId: String, baseURL: String, apiKey: String) async {
        guard (refCounts[instanceId] ?? 0) <= 0 else { return }
        // Race-Fix (Audit T7): Vorher wurde `loadedModels` erst NACH dem awaited Netzwerk-POST
        // bereinigt – ein re-entrantes acquire() konnte währenddessen die instanceId eines
        // gerade entladenen Modells aus dem Cache zurückgeben. Die Buchhaltung ist jetzt VOR
        // der Netzwerkarbeit sauber; schlägt der POST fehl, bleibt das Modell nur geladen
        // (harmlos, der nächste syncLoadedModels korrigiert den Zustand).
        loadedModels.removeValue(forKey: modelId)
        refCounts.removeValue(forKey: instanceId)
        idleTimers.removeValue(forKey: instanceId)
        await unloadModel(instanceId: instanceId, modelId: modelId, baseURL: baseURL, apiKey: apiKey)
    }
    
    /// Fragt LM Studio nach aktuell geladenen Modellen und gleicht sie ab.
    /// Nützlich beim App-Start oder nach Reconnect.
    func syncLoadedModels(baseURL: String, apiKey: String) async {
        guard let url = URL(string: normalizedBase(baseURL) + "/api/v1/models") else { return }
        var request = URLRequest(url: url, timeoutInterval: 5)
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelList = json["data"] as? [[String: Any]] else { return }
        
        // Bekannte Modelle eintragen falls wir sie noch nicht kennen
        for m in modelList {
            if let instanceId = m["id"] as? String ?? m["instance_id"] as? String,
               let modelId = m["model_key"] as? String ?? m["path"] as? String ?? m["id"] as? String,
               loadedModels[modelId] == nil {
                loadedModels[modelId] = instanceId
            }
        }
    }
    
    // MARK: - API Calls

    /// Fragt den Server ob das Modell bereits geladen ist.
    /// Gibt die instanceId zurück wenn gefunden, nil sonst.
    /// Nutzt Fuzzy-Matching: sucht ob der modelId-String (oder Teile davon) in den Server-Feldern
    /// id/model_key/path steckt oder umgekehrt — deckt den häufigsten Fall ab, wo LM Studio
    /// den vollen Hub-Pfad ("bartowski/Qwen2.5-7B-Instruct-GGUF") als id liefert,
    /// aber der User nur "Qwen2.5-7B-Instruct-GGUF" einträgt, oder umgekehrt.
    private func checkAlreadyLoaded(modelId: String, baseURL: String, apiKey: String) async -> String? {
        let base = normalizedBase(baseURL)
        
        // LM Studio v1 API
        if let id = await queryModelsEndpoint(base + "/api/v1/models", modelId: modelId, apiKey: apiKey, format: .lmStudioV1) {
            return id
        }
        // OpenAI-kompatibler Fallback (/v1/models) — für Ollama, llama.cpp etc.
        if let id = await queryModelsEndpoint(base + "/v1/models", modelId: modelId, apiKey: apiKey, format: .openAI) {
            return id
        }
        // Ollama (/api/tags)
        if let id = await queryModelsEndpoint(base + "/api/tags", modelId: modelId, apiKey: apiKey, format: .ollama) {
            return id
        }
        return nil
    }

    private enum ModelsFormat { case lmStudioV1, openAI, ollama }

    private func queryModelsEndpoint(_ urlString: String, modelId: String, apiKey: String, format: ModelsFormat) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 4)
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Modelle aus verschiedenen Formaten extrahieren
        var entries: [[String: Any]] = []
        switch format {
        case .lmStudioV1:
            entries = json["data"] as? [[String: Any]] ?? []
        case .openAI:
            entries = json["data"] as? [[String: Any]] ?? []
        case .ollama:
            // Ollama: { "models": [{ "name": "llama3.2", ... }] }
            entries = (json["models"] as? [[String: Any]])?.map { m in
                var e = m
                e["id"] = m["name"] // Normalize
                return e
            } ?? []
        }

        let needle = modelId.lowercased()
        for entry in entries {
            // Alle möglichen Bezeichner die LM Studio/Ollama liefern kann
            let candidates: [String] = [
                entry["id"] as? String,
                entry["instance_id"] as? String,
                entry["model_key"] as? String,
                entry["path"] as? String,
                entry["name"] as? String,
            ].compactMap { $0?.lowercased() }

            for candidate in candidates {
                if isMatch(needle: needle, in: candidate) {
                    // instanceId bevorzugen, sonst id nehmen
                    let instanceId = entry["instance_id"] as? String ?? entry["id"] as? String ?? candidate
                    return instanceId
                }
            }
        }
        return nil
    }

    private func loadModel(modelId: String, baseURL: String, apiKey: String) async -> String? {

        guard let url = URL(string: normalizedBase(baseURL) + "/api/v1/models/load") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 60) // Laden kann dauern
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        
        let body: [String: Any] = ["model": modelId]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = data
        
        do {
            let (responseData, httpResponse) = try await URLSession.shared.data(for: request)
            let statusCode = (httpResponse as? HTTPURLResponse)?.statusCode ?? 0
            
            if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
                // LM Studio gibt instance_id oder id zurück
                if let instanceId = json["instance_id"] as? String {
                    AppLog.services.info("LMStudioModelManager: Modell '\(modelId)' geladen → instanceId: \(instanceId)")
                    return instanceId
                }
                if let instanceId = json["id"] as? String {
                    AppLog.services.info("LMStudioModelManager: Modell '\(modelId)' geladen → id: \(instanceId)")
                    return instanceId
                }
            }
            
            // Modell war bereits geladen (409 Conflict) → Liste abfragen
            if statusCode == 409 {
                return await resolveExistingInstance(modelId: modelId, baseURL: baseURL, apiKey: apiKey)
            }
            
            AppLog.services.error("LMStudioModelManager: Load fehlgeschlagen für '\(modelId)' (HTTP \(statusCode))")
            return nil
        } catch {
            AppLog.services.error("LMStudioModelManager: Netzwerkfehler beim Laden von '\(modelId)': \(error.localizedDescription)")
            return nil
        }
    }
    
    private func unloadModel(instanceId: String, modelId: String, baseURL: String, apiKey: String) async {
        guard let url = URL(string: normalizedBase(baseURL) + "/api/v1/models/unload") else { return }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        
        let body: [String: Any] = ["model": modelId]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        request.httpBody = data
        
        do {
            let (_, httpResponse) = try await URLSession.shared.data(for: request)
            let status = (httpResponse as? HTTPURLResponse)?.statusCode ?? 0
            AppLog.services.info("LMStudioModelManager: Modell instanceId '\(instanceId)' entladen (HTTP \(status))")
        } catch {
            AppLog.services.error("LMStudioModelManager: Fehler beim Entladen: \(error.localizedDescription)")
        }
    }
    
    /// Falls das Modell schon geladen war (409), suchen wir die instanceId in der Liste.
    private func resolveExistingInstance(modelId: String, baseURL: String, apiKey: String) async -> String? {
        guard let url = URL(string: normalizedBase(baseURL) + "/api/v1/models") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelList = json["data"] as? [[String: Any]] else { return nil }
        
        // Suche nach dem Modell anhand des modelId-Strings (Fuzzy-Match reicht hier)
        for m in modelList {
            let id = m["id"] as? String ?? ""
            let modelKey = m["model_key"] as? String ?? ""
            let path = m["path"] as? String ?? ""
            
            if isMatch(needle: modelId, in: id) || 
               isMatch(needle: modelId, in: modelKey) || 
               isMatch(needle: modelId, in: path) {
                let instanceId = m["instance_id"] as? String ?? id
                AppLog.services.info("LMStudioModelManager: Bereits geladen: '\(modelId)' → instanceId: \(instanceId)")
                return instanceId
            }
        }
        
        // Kein Fuzzy-Match gefunden → bewusst KEIN Fallback auf "erstes Modell in der Liste":
        // das würde bei mehreren gleichzeitig geladenen Modellen (z.B. Haupt- + Hintergrundmodell)
        // eine falsche instanceId zurückgeben, unter der dann refCount/Idle-Timer für das FALSCHE
        // Modell geführt würden – ein zu Unrecht abgeleitetes Entladen des falschen Modells wäre
        // schlimmer als ein nil hier, das den Aufrufer sauber "nicht gefunden" behandeln lässt.
        return nil
    }
    
    // MARK: - Helper
    
    /// Entscheidet, ob für dieses Profil automatisches Laden/Entladen über die LM Studio API
    /// versucht werden soll (u.a. Haupt- UND Hintergrund-Modell-Verwaltung, Titel-Generierung,
    /// Bildbeschreibung).
    ///
    /// `.lmStudioNative` ist eine EXPLIZITE Nutzerauswahl ("das ist LM Studio") – unabhängig vom
    /// Host verwaltbar, auch wenn übers Netzwerk statt localhost/127.0.0.1 erreicht (z.B. vom
    /// Laptop per Tailscale/LAN-IP auf den Desktop-Rechner). Vorher schlug der Localhost-Check
    /// HIER fehl, sobald die baseURL keine localhost/127.0.0.1-Adresse war – dadurch liefen
    /// weder Haupt-Modell-Laden noch Hintergrund-Jobs (Titel, Bildbeschreibung) je an, sobald
    /// LM Studio remote (z.B. per Tailscale) angesprochen wurde.
    ///
    /// Der Localhost-Check bleibt NUR für `.openAICompatible` relevant, da darunter auch echte
    /// Cloud-APIs (OpenAI, Groq, …) laufen können, gegen die LM-Studio-spezifische Endpunkte
    /// (/api/v1/models/load etc.) sinnlos bzw. potenziell schädlich wären.
    func isLMStudioLocal(profile: EndpointProfile) -> Bool {
        if profile.provider == .lmStudioNative { return true }
        guard profile.provider == .openAICompatible else { return false }
        let base = profile.baseURL.lowercased()
        return base.contains("localhost") || base.contains("127.0.0.1")
    }
    
    func effectiveLMStudioModelId(profile: EndpointProfile, useBackground: Bool) -> String {
        if useBackground {
            let id = profile.backgroundJobModelLMStudioId.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = profile.backgroundJobModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveFallback = fallback.isEmpty ? profile.model : fallback
            return id.isEmpty ? effectiveFallback : id
        } else {
            let id = profile.lmStudioModelId.trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty ? profile.model : id
        }
    }
    
    private func normalizedBase(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        // Entferne bekannte Pfad-Suffixe
        for suffix in ["/v1/chat/completions", "/api/v0/chat/completions", "/api/chat", "/v1", "/api/v0", "/api/v1"] {
            if s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)) }
        }
        return s
    }
    
    private func isMatch(needle: String, in candidate: String) -> Bool {
        // Leere Begriffe matchen NICHTS (Audit T7): `needle.contains("")` bzw. der Fuzzy-
        // Vergleich unten wäre für einen leeren Kandidaten immer true – ein leerer
        // Server-Eintrag hätte damit jedes gesuchte Modell "treffen" können.
        guard !needle.isEmpty, !candidate.isEmpty else { return false }

        let needle = needle.lowercased()
        let candidate = candidate.lowercased()
        
        if needle == candidate { return true }
        
        guard let range = candidate.range(of: needle) else {
            // Umgekehrter Fall (candidate in needle) - z.B. wenn User versehentlich den vollen Pfad kopiert hat
            return needle.contains(candidate)
        }
        
        // Prüfe Zeichen DAVOR
        if range.lowerBound > candidate.startIndex {
            let prevChar = candidate[candidate.index(before: range.lowerBound)]
            if prevChar.isLetter || prevChar.isNumber { return false }
        }
        
        // Prüfe Zeichen DANACH
        if range.upperBound < candidate.endIndex {
            let nextChar = candidate[range.upperBound]
            if nextChar.isLetter || nextChar.isNumber || nextChar == "." { return false }
        }
        
        return true
    }
}

