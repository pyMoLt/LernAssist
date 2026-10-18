import Foundation
import Security
import os

/// Dünner Wrapper um die macOS-Keychain (Audit P1): speichert die API-Keys der
/// Endpunkt-Profile außerhalb von `settings.json`. Der Account ist die Profil-ID,
/// der Service ein app-fester String – beim Löschen eines Profils kann der Key über
/// `deleteAPIKey` mit entfernt werden.
///
/// `nonisolated`, weil das Projekt `-default-isolation=MainActor` nutzt: SecItem-Aufrufe
/// sind thread-sicher und sollen den Main-Actor nie blockieren.
nonisolated enum KeychainStore {
    private static let service = "com.pymolt.LernAssist.apiKeys"

    /// Unit-Tests schreiben nie in den echten Schlüsselbund – sonst landeten Test-Profile mit
    /// Fantasie-Keys im Login-Schlüsselbund des Nutzers.
    private static var inMemory: Bool { AppStorageLocation.isRunningUnitTests }
    private static let testLock = NSLock()
    nonisolated(unsafe) private static var testStore: [String: String] = [:]
    private static func testValue(_ key: String) -> String? {
        testLock.lock(); defer { testLock.unlock() }
        return testStore[key]
    }
    private static func setTestValue(_ value: String?, _ key: String) {
        testLock.lock(); defer { testLock.unlock() }
        testStore[key] = value
    }

    /// Speichert den API-Key eines Profils. Leerstring löscht den Eintrag (Profil ohne Key).
    static func setAPIKey(_ key: String, forProfileID id: UUID) {
        if inMemory { setTestValue(key.isEmpty ? nil : key, id.uuidString); return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]

        guard !key.isEmpty else {
            deleteAPIKey(forProfileID: id)
            return
        }

        let updateAttributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = Data(key.utf8)
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                AppLog.persistence.error("Keychain: API-Key für Profil \(id.uuidString) konnte nicht gespeichert werden (Status \(addStatus))")
            }
        } else if updateStatus != errSecSuccess {
            AppLog.persistence.error("Keychain: API-Key für Profil \(id.uuidString) konnte nicht aktualisiert werden (Status \(updateStatus))")
        }
    }

    /// Ergebnis eines Lesezugriffs. `failed` (z. B. ACL-Wechsel nach einem ad-hoc-signierten
    /// Neu-Build, gesperrter Schlüsselbund) ist bewusst von `notFound` getrennt: Ein Lesefehler
    /// darf nie als „Profil ohne Key“ interpretiert und dann beim nächsten Speichern als
    /// Löschauftrag zurückgeschrieben werden (Audit 2026-10-12, Chat-Kern H7).
    enum ReadResult: Equatable {
        case found(String)
        case notFound
        case failed(OSStatus)
    }

    static func readAPIKey(forProfileID id: UUID) -> ReadResult {
        if inMemory { return testValue(id.uuidString).map { .found($0) } ?? .notFound }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            AppLog.persistence.error("Keychain: API-Key für Profil \(id.uuidString) konnte nicht gelesen werden (Status \(status))")
            return .failed(status)
        }
        return .found(key)
    }

    /// Liest den API-Key eines Profils. Gibt "" zurück, wenn kein Eintrag existiert oder das
    /// Lesen fehlschlägt (für reine Anzeige-/Request-Zwecke).
    static func apiKey(forProfileID id: UUID) -> String {
        if case .found(let key) = readAPIKey(forProfileID: id) { return key }
        return ""
    }

    // MARK: Benannte Geheimnisse (z. B. Exa-API-Key)

    private static func secretQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service + ".secrets",
         kSecAttrAccount as String: account]
    }

    /// Speichert ein benanntes Geheimnis. Leerstring löscht den Eintrag.
    static func setSecret(_ value: String, account: String) {
        if inMemory { setTestValue(value.isEmpty ? nil : value, "secret." + account); return }
        let query = secretQuery(account)
        guard !value.isEmpty else { SecItemDelete(query as CFDictionary); return }
        let update = [kSecValueData as String: Data(value.utf8)]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = Data(value.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let status = SecItemAdd(add as CFDictionary, nil)
            if status != errSecSuccess {
                AppLog.persistence.error("Keychain: Geheimnis \(account) konnte nicht gespeichert werden (Status \(status))")
            }
        }
    }

    static func secret(account: String) -> String {
        if inMemory { return testValue("secret." + account) ?? "" }
        var query = secretQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Entfernt den API-Key eines Profils aus der Keychain (z.B. beim Löschen des Profils).
    static func deleteAPIKey(forProfileID id: UUID) {
        if inMemory { setTestValue(nil, id.uuidString); return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            AppLog.persistence.error("Keychain: API-Key für Profil \(id.uuidString) konnte nicht gelöscht werden (Status \(status))")
        }
    }
}
