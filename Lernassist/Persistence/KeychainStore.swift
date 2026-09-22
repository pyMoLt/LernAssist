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

    /// Speichert den API-Key eines Profils. Leerstring löscht den Eintrag (Profil ohne Key).
    static func setAPIKey(_ key: String, forProfileID id: UUID) {
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

    /// Liest den API-Key eines Profils. Gibt "" zurück, wenn kein Eintrag existiert.
    static func apiKey(forProfileID id: UUID) -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                AppLog.persistence.error("Keychain: API-Key für Profil \(id.uuidString) konnte nicht gelesen werden (Status \(status))")
            }
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Entfernt den API-Key eines Profils aus der Keychain (z.B. beim Löschen des Profils).
    static func deleteAPIKey(forProfileID id: UUID) {
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
