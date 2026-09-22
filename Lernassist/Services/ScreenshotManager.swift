import Foundation
import AppKit
import CoreGraphics
import os

/// `nonisolated`, damit `imageToBase64` (synchrone TIFF→PNG-Konvertierung) tatsächlich auf dem
/// Hintergrund-Thread läuft, wenn es aus einem `Task.detached` heraus aufgerufen wird – ohne diese
/// Markierung würde das Projekt-Setting `-default-isolation=MainActor` den Aufruf trotzdem wieder
/// auf den Main-Thread ziehen (derselbe Bug-Typ wie bei CodingEnvironment, hier nur als Compiler-
/// Warnung statt spürbarem Hänger sichtbar, da die Bilder meist klein sind).
nonisolated final class ScreenshotManager {
    static let shared = ScreenshotManager()

    /// Polling-Intervall/-Budget beim Warten auf das PNG (Audit T5): 5K-Retina-Screenshots
    /// sind zweistellig MB groß – ein fixes 200-ms-Warten (vorher) lief für große Aufnahmen
    /// zu früh leer, der Screenshot galt fälschlich als "fehlgeschlagen".
    private static let pollInterval: TimeInterval = 0.05
    private static let pollAttempts = 100 // 0,05 s × 100 = 5 s Budget

    func captureScreenshot(completion: @escaping (NSImage?) -> Void) {
        // Screen-Recording-Berechtigung vorab prüfen (Audit T5): Fehlt sie, läuft screencapture
        // ins Leere bzw. wird vom System blockiert – vorher kam nur ein kryptisches
        // "Datei nicht gefunden" beim Nutzer an.
        if !CGPreflightScreenCaptureAccess() {
            AppLog.services.warning("Screen-Recording-Berechtigung fehlt möglicherweise (Systemeinstellungen > Datenschutz & Sicherheit > Bildschirmaufnahme) – der Screenshot kann scheitern.")
        }

        let task = Process()
        // executableURL statt des deprecateden launchPath (Audit 2.7).
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")

        // UUID-Dateiname statt Fixname (Audit T5): Parallele Aufnahmen überschrieben sich
        // sonst gegenseitig.
        let tempPath = NSTemporaryDirectory() + "lernassist_snap_\(UUID().uuidString).png"
        try? FileManager.default.removeItem(atPath: tempPath)

        task.arguments = ["-i", "-x", tempPath]

        task.terminationHandler = { process in
            let exitOk = process.terminationStatus == 0
            func poll(_ attempt: Int) {
                let size = (try? FileManager.default.attributesOfItem(atPath: tempPath))?[.size] as? Int ?? 0
                if exitOk, size > 0, let image = NSImage(contentsOfFile: tempPath) {
                    try? FileManager.default.removeItem(atPath: tempPath)
                    completion(image)
                } else if attempt < Self.pollAttempts, exitOk {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.pollInterval) { poll(attempt + 1) }
                } else {
                    // Datei nie wieder liegen lassen (Audit T5) und den Abbruch begründen.
                    try? FileManager.default.removeItem(atPath: tempPath)
                    if !exitOk {
                        AppLog.services.info("Screenshot abgebrochen (screencapture Exit-Code \(process.terminationStatus)) – vermutlich per ESC abgebrochen oder Berechtigung verweigert.")
                    } else {
                        AppLog.services.error("Screenshot-Datei wurde innerhalb von \(Int(Double(Self.pollAttempts) * Self.pollInterval))s nicht lesbar: \(tempPath)")                    }
                    completion(nil)
                }
            }
            DispatchQueue.main.async { poll(0) }
        }

        do {
            try task.run()
        } catch {
            AppLog.services.error("screencapture konnte nicht gestartet werden: \(error.localizedDescription)")
            completion(nil)
        }
    }

    /// PNG-Base64 für den Modell-Payload. Vor dem Encodieren wird auf max. `maxPixel` Pixel an
    /// der langen Kante herunterskaliert (Audit T5): Ein 5K-Retina-Screenshot erzeugt sonst
    /// schnell >10 MB Nutzlast, die durch die komplette Pipeline (Base64, JSON, HTTP) muss –
    /// Vision-Modelle sehen die zusätzliche Auflösung ohnehin nicht.
    func imageToBase64(_ image: NSImage, maxPixel: CGFloat = 1600) -> String? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        let longEdge = CGFloat(max(bitmap.pixelsWide, bitmap.pixelsHigh))
        guard longEdge > maxPixel else {
            return bitmap.representation(using: .png, properties: [:])?.base64EncodedString()
        }

        let scale = maxPixel / longEdge
        let newSize = NSSize(width: CGFloat(bitmap.pixelsWide) * scale,
                             height: CGFloat(bitmap.pixelsHigh) * scale)
        let small = NSImage(size: newSize)
        small.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize))
        small.unlockFocus()

        guard let smallTiff = small.tiffRepresentation,
              let smallBitmap = NSBitmapImageRep(data: smallTiff),
              let pngData = smallBitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return pngData.base64EncodedString()
    }
}
