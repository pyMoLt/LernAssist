import Foundation
import AppKit

/// Render-Cache für dekodierte Screenshots, jetzt mit Festplatten-Fallback.
///
/// - `NSCache` statt Dictionary: verwirft Einträge automatisch unter Speicherdruck bzw.
///   ab `countLimit` (bisheriger Bug: unbegrenztes RAM-Wachstum bei vielen Screenshots).
/// - Bilder, die nicht mehr im Speicher sind (z.B. nach App-Neustart), werden bei Bedarf
///   von Platte nachgeladen – geschrieben werden sie von `SessionStore` beim Persistieren.
final class ImageStore {
    static let shared = ImageStore()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 60 // genug für eine lange Session, ohne unbegrenzt zu wachsen
        return c
    }()

    func setImage(_ image: NSImage, for id: UUID) {
        cache.setObject(image, forKey: id.uuidString as NSString)
    }

    /// Synchroner Speicher-Cache-Zugriff (kein Disk-I/O).
    func getImage(for id: UUID) -> NSImage? {
        cache.object(forKey: id.uuidString as NSString)
    }

    /// Lädt ein Bild von Platte (Hintergrund-Thread), falls es nicht mehr im Speicher-Cache ist.
    /// Genutzt für Bilder aus wiederhergestellten Chats, deren Base64-Daten nicht mehr im
    /// Message-Objekt vorliegen (siehe SessionStore: Base64 wird beim Persistieren entfernt).
    func loadFromDisk(for id: UUID) async -> NSImage? {
        if let cached = getImage(for: id) { return cached }
        let url = AppStorageLocation.imageFile(id: id)
        let image = await Task.detached(priority: .userInitiated) {
            NSImage(contentsOf: url)
        }.value
        guard let image else { return nil }
        setImage(image, for: id)
        return image
    }

    func removeImage(for id: UUID) {
        cache.removeObject(forKey: id.uuidString as NSString)
    }
}
