import Foundation
import PDFKit
import AppKit
import Combine

/// Repräsentiert den aktuellen Fortschritt der Dokumentenverarbeitung
struct DocumentProcessingStatus: Equatable {
    var isProcessing: Bool = false
    var statusText: String = ""
    var progress: Double = 0.0
    var estimatedTokens: Int = 0
}

/// Zuständig für die Extraktion von Text und Bildern aus Dokumenten (PDF, TXT, MD)
class DocumentProcessor: ObservableObject {
    static let shared = DocumentProcessor()
    
    @Published var currentStatus: DocumentProcessingStatus = DocumentProcessingStatus()
    
    private init() {}

    /// Budget pro Dokument (Audit T6): Ein 200-Seiten-PDF hätte sonst bis zu 200 einzelne
    /// Vision-Requests und ebenso viele Base64-Anhänge ausgelöst.
    nonisolated private static let maxDescribedImages = 12

    /// Verarbeitet ein einzelnes Dokument und aktualisiert die UI asynchron über das ChatViewModel
    func processDocument(url: URL, documentId: UUID, viewModel: ChatViewModel, detailLevel: String) {
        viewModel.updateDocument(id: documentId, status: .processing, progress: 0.1, statusText: "Lese Datei...", extractedText: "")

        Task {
            let fileExtension = url.pathExtension.lowercased()
            var extractedText = ""
            var extractedImages: [String] = []

            do {
                if fileExtension == "pdf" {
                    // extractImagesFromPDF hier (MainActor) lesen und als Parameter übergeben –
                    // processPDF läuft bewusst off-main und darf nicht auf ViewModel-State zugreifen.
                    let (text, images) = try await self.processPDF(
                        url: url, documentId: documentId, viewModel: viewModel,
                        detailLevel: detailLevel, extractImages: viewModel.extractImagesFromPDF,
                        imageBudget: viewModel.documentImageBudget
                    )
                    extractedText = text
                    extractedImages = images
                } else if ["txt", "md", "csv", "json"].contains(fileExtension) {
                    extractedText = try await Self.readTextFile(at: url)
                } else if ["doc", "docx", "rtf", "ppt", "pptx"].contains(fileExtension) {
                    await MainActor.run {
                        viewModel.updateDocument(id: documentId, status: .processing, progress: 0.3, statusText: "Extrahiere formatierten Text...", extractedText: "")
                    }

                    // Text: NSAttributedString funktioniert für die reine Textextraktion über alle
                    // Formate hinweg brauchbar (auch wenn sie faktisch NIE eingebettete Bilder liefert).
                    // Bewusst off-main (Audit T6): Der Import großer Office-Dateien kann Sekunden
                    // dauern – auf dem Main-Thread (MainActor-Default-Isolation) fror die UI dafür.
                    let attrStr = await Self.officeAttributedString(from: url)
                    if let attrStr {
                        extractedText = attrStr.string
                    } else if let text = try? await Self.readTextFile(at: url) {
                        extractedText = text
                    } else {
                        extractedText = "(Konnte Dokumenteninhalt nicht extrahieren. Format wird möglicherweise nicht nativ unterstützt.)"
                    }

                    // Bilder: .docx/.pptx sind ZIP-Archive → zuverlässige direkte Extraktion aus
                    // word/media/ bzw. ppt/media/ (siehe extractOfficeMediaImages). Für die älteren
                    // Binärformate .doc/.ppt sowie .rtf gibt es das nicht – dort bleibt nur der
                    // NSAttributedString-attachment-Weg als Best-effort-Fallback (liefert oft nichts,
                    // aber immerhin keinen Fehler).
                    if viewModel.extractImagesFromPDF {
                        let images: [NSImage]
                        if ["docx", "pptx"].contains(fileExtension) {
                            images = await extractOfficeMediaImages(from: url)
                        } else {
                            images = attrStr.map(extractLegacyAttachmentImages) ?? []
                        }
                        let (imageText, base64Images, _) = await describeEmbeddedImages(
                            images, documentId: documentId, viewModel: viewModel, detailLevel: detailLevel
                        )
                        if !imageText.isEmpty { extractedText += "\n\n" + imageText }
                        extractedImages = base64Images
                    }
                } else {
                    extractedText = "(Dateiformat \(fileExtension) wird nicht unterstützt.)"
                }

                await MainActor.run {
                    viewModel.updateDocument(
                        id: documentId,
                        status: .completed,
                        progress: 1.0,
                        statusText: "Abgeschlossen",
                        extractedText: extractedText,
                        images: extractedImages
                    )
                }
            } catch {
                await MainActor.run {
                    viewModel.updateDocument(
                        id: documentId,
                        status: .failed,
                        progress: 0.0,
                        statusText: "Fehler: \(error.localizedDescription)",
                        extractedText: ""
                    )
                }
            }
        }
    }

    /// PDF-Verarbeitung. `nonisolated`, damit PDFKit-Decoding und Textextraktion OFF-Main laufen
    /// (Audit T6): Unter der MainActor-Default-Isolation dieses Projekts fror die UI bei großen
    /// PDFs für die volle Dauer der Verarbeitung ein. UI-Updates laufen über MainActor.run.
    nonisolated private func processPDF(url: URL, documentId: UUID, viewModel: ChatViewModel, detailLevel: String, extractImages: Bool, imageBudget: Int? = nil) async throws -> (String, [String]) {
        // Vorher: Ein Ladefehler kehrte als Fehler-STRING im extrahierten Text zurück und der
        // Status lief auf .completed (Audit T6) – der Nutzer sah ein "fertiges" Dokument, dessen
        // ganzer Inhalt "FEHLER BEIM LADEN DES PDFS" war. Jetzt: throw → Status .failed.
        guard let pdfDocument = PDFDocument(url: url) else {
            throw CocoaError(.fileReadCorruptFile,
                             userInfo: [NSLocalizedDescriptionKey:
                                "PDF konnte nicht gelesen werden (\(url.lastPathComponent)) – beschädigt oder kein gültiges PDF."])
        }

        let pageCount = pdfDocument.pageCount
        var fullText = "--- INHALT VON \(url.lastPathComponent) ---\n"
        var images: [String] = []
        // Audit H9: Bild-Budget gilt pro DOKUMENT, nicht pro Seite – der Caller zieht die je
        // Seite verbrauchten Beschreibungen vom Gesamtbudget ab.
        let totalImageBudget = imageBudget ?? Self.maxDescribedImages
        var remainingImageBudget = totalImageBudget
        var pagesWithSkippedImages: [Int] = []

        // Komponierte Fortschritts-Skala (Audit T6): Eine einzige monoton steigende Kurve über
        // die Seiten (0.1...0.9) – vorher sprang der Balken beim Starten der Bild-Beschreibungen
        // von ~1.0 zurück auf 0.4 und wieder vor, weil Text- und Bild-Phase getrennte,
        // nicht komponierte Skalen nutzten.
        for i in 0..<pageCount {
            guard let page = pdfDocument.page(at: i) else { continue }

            let pageStartProgress = 0.1 + 0.8 * Double(i) / Double(pageCount)
            let pageEndProgress = 0.1 + 0.8 * Double(i + 1) / Double(pageCount)
            await MainActor.run {
                viewModel.updateDocument(id: documentId, status: .processing, progress: pageStartProgress, statusText: "Extrahiere Seite \(i + 1) von \(pageCount)...", extractedText: "")
            }

            // Text extrahieren
            if let pageText = page.string {
                fullText += "--- SEITE \(i + 1) ---\n\(pageText)\n"
            }

            // Echte, im PDF eingebettete Bilder extrahieren (JPEGs)
            if extractImages, let cgPage = page.pageRef {
                let extractor = PDFPageImageExtractor()
                let extractedImages = extractor.extractImages(from: cgPage)

                if !extractedImages.isEmpty {
                    if remainingImageBudget > 0 {
                        let (imageText, base64Images, usedBudget) = await describeEmbeddedImages(
                            extractedImages, documentId: documentId, viewModel: viewModel, detailLevel: detailLevel, pageInfo: "auf Seite \(i + 1)",
                            progressRange: (pageStartProgress + 0.5 * (pageEndProgress - pageStartProgress), pageEndProgress),
                            budget: remainingImageBudget
                        )
                        remainingImageBudget -= usedBudget

                        if !imageText.isEmpty {
                            fullText += "\n[Extrahierte Bilder von Seite \(i + 1)]\n\(imageText)\n"
                        }
                        images.append(contentsOf: base64Images)
                    } else {
                        pagesWithSkippedImages.append(i + 1)
                    }
                }
            }
        }

        // Audit H9: Transparenz über durch das Dokument-Budget nicht mehr beschriebene Bilder.
        if !pagesWithSkippedImages.isEmpty {
            fullText += "\n[Das Bild-Budget von \(totalImageBudget) Beschreibungen pro Dokument war ab Seite \(pagesWithSkippedImages.first!) erschöpft – Bilder auf \(pagesWithSkippedImages.count) weiteren Seiten wurden aus Kontext-/Kostengründen nicht mehr beschrieben.]\n"
        }

        return (fullText, images)
    }

    /// Off-main Textdatei-Lesezugriff (Audit T6): Auch String(contentsOf:) kann bei großen
    /// Dateien spürbar dauern – gehört nicht auf den Main-Thread.
    nonisolated private static func readTextFile(at url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try String(contentsOf: url, encoding: .utf8)
        }.value
    }

    /// Off-main NSAttributedString-Import (Audit T6): Der Office-Importer ist synchron und kann
    /// bei großen Dateien Sekunden dauern.
    nonisolated private static func officeAttributedString(from url: URL) async -> NSAttributedString? {
        // NSAttributedString ist nicht Sendable – über eine Box aus dem Hintergrund-Task holen
        // (der String wird danach nur noch gelesen).
        final class Box: @unchecked Sendable { let value: NSAttributedString?; init(_ v: NSAttributedString?) { value = v } }
        return await Task.detached(priority: .userInitiated) {
            Box(try? NSAttributedString(url: url, options: [:], documentAttributes: nil))
        }.value.value
    }

    /// Fallback für die älteren Binärformate .doc/.ppt sowie .rtf (keine ZIP-Container, daher nicht
    /// per Entpacken lesbar): versucht, eingebettete Bilder als NSTextAttachment-Runs aus AppKits
    /// Office-Importer zu lesen. In der Praxis liefert das so gut wie nie etwas – der Importer
    /// unterstützt praktisch nur einfache INLINE-Bilder zuverlässig, keine frei platzierten/
    /// textumflossenen. Liefert dann schlicht eine leere Liste statt eines Fehlers.
    private func extractLegacyAttachmentImages(from attrStr: NSAttributedString) -> [NSImage] {
        var images: [NSImage] = []
        let fullRange = NSRange(location: 0, length: attrStr.length)
        attrStr.enumerateAttribute(.attachment, in: fullRange, options: []) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            if let image = attachment.image {
                images.append(image)
            } else if let wrapper = attachment.fileWrapper,
                      let data = wrapper.regularFileContents,
                      let image = NSImage(data: data) {
                images.append(image)
            }
        }
        return images
    }

    /// Extrahiert eingebettete Bilder aus .docx/.pptx durch direktes Entpacken des ZIP-Containers
    /// (word/media/ bzw. ppt/media/). .docx/.pptx SIND ZIP-Archive mit fest definierter Struktur –
    /// das ist der zuverlässige Weg an eingebettete Bilder heranzukommen, im Gegensatz zu AppKits
    /// NSAttributedString-Importer, der in der Praxis so gut wie nie ein NSTextAttachment für
    /// eingebettete Bilder liefert (bestätigt durch Testlauf: Dokumente wurden nur als Text
    /// durchgereicht, nie mit tatsächlich extrahierten/beschriebenen Bildern).
    ///
    /// `nonisolated`, weil hier ein externer Prozess (`/usr/bin/unzip`) gestartet und dessen Ende
    /// abgewartet wird – ohne diese Markierung würde die MainActor-Default-Isolation dieses Projekts
    /// (siehe CodingEnvironment/ScreenshotManager, wo genau dieser Bug bereits gefunden wurde) diese
    /// Arbeit implizit auf den Main-Thread ziehen und die UI für die Dauer des Entpackens einfrieren.
    nonisolated private func extractOfficeMediaImages(from url: URL) async -> [NSImage] {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("LernAssist-media-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)) != nil else { return [] }
        defer { try? fm.removeItem(at: tempDir) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // -o: ohne Rückfrage überschreiben, -q: leise. Nur die Medien-Ordner entpacken (docx:
        // word/media, pptx: ppt/media) – der Rest der ZIP-Struktur (XML, Styles, ...) wird nicht
        // gebraucht.
        process.arguments = ["-o", "-q", url.path, "word/media/*", "ppt/media/*", "-d", tempDir.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let succeeded: Bool = await withCheckedContinuation { continuation in
            // Watchdog (Audit T6): unzip lief vorher ohne jedes Timeout und konnte theoretisch
            // ewig hängen. Nach 30 s wird der Prozess zwangsweise beendet.
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled, process.isRunning else { return }
                process.terminate()
            }
            process.terminationHandler = { proc in
                watchdog.cancel()
                // unzip liefert Exit-Code 11 ("nichts gefunden"), wenn nur einer der beiden
                // Medien-Pfade existiert (z.B. .docx hat kein ppt/media) – kein echter Fehler.
                continuation.resume(returning: proc.terminationStatus == 0 || proc.terminationStatus == 11)
            }
            do {
                try process.run()
            } catch {
                watchdog.cancel()
                continuation.resume(returning: false)
            }
        }
        guard succeeded else { return [] }

        let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp"]
        var images: [NSImage] = []
        
        // docx: lexikografische Sortierung nach Dateiname (keine Seitenreihenfolge im ZIP)
        let wordMediaDir = tempDir.appendingPathComponent("word/media")
        if let files = try? fm.contentsOfDirectory(at: wordMediaDir, includingPropertiesForKeys: nil) {
            for fileURL in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard supportedExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
                if let image = NSImage(contentsOf: fileURL) { images.append(image) }
            }
        }
        
        // pptx: Slide-Reihenfolge via XML-Parsing (ppt/slides/_rels/slide*.xml.rels)
        // Falls das Parsing fehlschlägt → Fallback auf lexikografische Sortierung
        let pptMediaDir = tempDir.appendingPathComponent("ppt/media")
        if fm.fileExists(atPath: pptMediaDir.path),
           let pptFiles = try? fm.contentsOfDirectory(at: pptMediaDir, includingPropertiesForKeys: nil),
           !pptFiles.isEmpty {
            
            let orderedPptImages = extractPptxImagesInSlideOrder(tempDir: tempDir, mediaDir: pptMediaDir, supported: supportedExtensions)
            if orderedPptImages.isEmpty {
                // Fallback: lexikografische Sortierung
                for fileURL in pptFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    guard supportedExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
                    if let image = NSImage(contentsOf: fileURL) { images.append(image) }
                }
            } else {
                images.append(contentsOf: orderedPptImages)
            }
        }
        
        return images
    }
    
    /// Liest die pptx-Relationship-XMLs (ppt/slides/_rels/slide*.xml.rels) und gibt Bilder
    /// in der Reihenfolge der Slides zurück. Jeder Slide referenziert seine Bilder via rId-Links.
    /// Falls das XML-Parsing fehlschlägt, wird eine leere Liste zurückgegeben (→ Fallback).
    nonisolated private func extractPptxImagesInSlideOrder(tempDir: URL, mediaDir: URL, supported: Set<String>) -> [NSImage] {
        let fm = FileManager.default
        let slidesDir = tempDir.appendingPathComponent("ppt/slides")
        let relsDir = slidesDir.appendingPathComponent("_rels")
        
        guard let relsFiles = try? fm.contentsOfDirectory(at: relsDir, includingPropertiesForKeys: nil) else { return [] }
        
        // Slide-Dateien numerisch sortieren: slide1.xml.rels, slide2.xml.rels, …
        let sortedRels = relsFiles
            .filter { $0.lastPathComponent.hasPrefix("slide") && $0.pathExtension == "rels" }
            .sorted { a, b in
                let numA = slideNumber(from: a.lastPathComponent) ?? Int.max
                let numB = slideNumber(from: b.lastPathComponent) ?? Int.max
                return numA < numB
            }
        
        guard !sortedRels.isEmpty else { return [] }
        
        var orderedImages: [NSImage] = []
        var seenPaths: Set<String> = []
        
        for relsFile in sortedRels {
            guard let xmlData = try? Data(contentsOf: relsFile),
                  let xmlString = String(data: xmlData, encoding: .utf8) else { continue }
            
            // Einfacher Regex-basierter Parser: sucht Target="../media/..." in den Relationships
            // Kein XMLParser, um Abhängigkeiten minimal zu halten und schnell zu sein.
            let pattern = #"Target\s*=\s*"\.\./(media/[^"]+)""#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(xmlString.startIndex..., in: xmlString)
            let matches = regex.matches(in: xmlString, range: range)
            
            for match in matches {
                guard let groupRange = Range(match.range(at: 1), in: xmlString) else { continue }
                let relativePath = String(xmlString[groupRange]) // e.g. "media/image1.png"
                guard !seenPaths.contains(relativePath) else { continue }
                
                let mediaURL = tempDir.appendingPathComponent("ppt").appendingPathComponent(relativePath)
                guard supported.contains(mediaURL.pathExtension.lowercased()),
                      let image = NSImage(contentsOf: mediaURL) else { continue }
                
                seenPaths.insert(relativePath)
                orderedImages.append(image)
            }
        }
        return orderedImages
    }
    
    /// Extrahiert die Slide-Nummer aus einem Dateinamen wie "slide3.xml.rels" → 3
    nonisolated private func slideNumber(from filename: String) -> Int? {
        // "slide3.xml.rels" → "3"
        let withoutRels = filename.replacingOccurrences(of: ".xml.rels", with: "")
        let digits = withoutRels.replacingOccurrences(of: "slide", with: "")
        return Int(digits)
    }



    /// Beschreibt eine Liste bereits extrahierter Bilder per Vision-Modell (eines nach dem anderen,
    /// mit Live-Vorschau des jeweils aktuellen Bildes in DocumentBadgeView) – gemeinsam genutzt von
    /// PDF-Seiten und Office-Dokument-Bildern.
    ///
    /// `nonisolated`, damit das JPEG-Encoding off-main läuft (Audit T6). Der Fortschritt wird in
    /// das übergebene Intervall interpoliert, statt einer eigenen festen Skala (Audit T6:
    /// nicht komponierte Skalen ließen den Balken rückwärts springen).
    nonisolated private func describeEmbeddedImages(
        _ images: [NSImage], documentId: UUID, viewModel: ChatViewModel, detailLevel: String, pageInfo: String? = nil,
        progressRange: (from: Double, to: Double) = (0.4, 0.9),
        // Default-Argumente werden außerhalb der Instanz-/Actor-Isolation ausgewertet; `Self` ist
        // hier deshalb nicht zulässig. Der Wert entspricht dem Dokument-Budget oben.
        budget: Int = 12
    ) async -> (text: String, base64Images: [String], usedBudget: Int) {
        guard !images.isEmpty, budget > 0 else { return ("", [], 0) }

        // Budget (Audit T6): Nur die ersten N Bilder beschreiben UND anhängen – ein Dokument
        // mit hunderten eingebetteten Bildern hätte sonst hundertfache Modell-Roundtrips
        // und ebenso viele Base64-Anhänge ausgelöst.
        // Audit H9: Der PDF-Pfad rief diese Funktion pro SEITE mit dem vollen Budget auf –
        // ein mehrseitiges PDF sprengte das "Budget pro Dokument" (12 × Seitenzahl). Der
        // Caller reicht jetzt sein verbleibendes Dokument-Budget herein und zieht die
        // tatsächlich beschriebenen Bilder ab.
        let capped = Array(images.prefix(budget))

        var descriptions = ""
        var base64Images: [String] = []
        for (idx, nsImage) in capped.enumerated() {
            guard let tiff = nsImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.6])
            else { continue }

            let base64 = jpegData.base64EncodedString()
            base64Images.append(base64)

            let progress = progressRange.from + (progressRange.to - progressRange.from) * Double(idx + 1) / Double(capped.count)
            await MainActor.run {
                viewModel.updateDocument(id: documentId, status: .processing, progress: progress,
                                          statusText: "Beschreibe Bild \(idx + 1) von \(capped.count)...",
                                          extractedText: "", previewImageBase64: base64)
            }

            let prompt = "Bitte beschreibe alle Bilder, Diagramme, Grafiken und Tabellen in diesem Dokumentausschnitt detailliert. Detailgrad: \(detailLevel). Ignoriere normalen Text, fokussiere dich auf visuelle Inhalte."
            // sendInvisiblePrompt liefert bei Netzwerk-/HTTP-Fehlern nil – dann wird keine
            // (irreführende) Fehlerbeschreibung in den Dokumenttext übernommen.
            guard let visionResult = await viewModel.sendInvisiblePrompt(
                prompt, context: [], imageBase64: base64, useBackgroundJobModel: true
            ) else { continue }
            let suffix = pageInfo ?? "im Dokument"
            descriptions += "[Bild \(idx + 1) \(suffix)]\n\(visionResult)\n\n"
        }
        if images.count > capped.count {
            descriptions += "[Von \(images.count) eingebetteten Bildern auf dieser Seite wurden nur die ersten \(capped.count) beschrieben – weitere wurden aus Kontext-/Kostengründen ausgelassen.]\n\n"
        }
        return (descriptions, base64Images, capped.count)
    }
}

// MARK: - PDF Image Extractor Helper
nonisolated private class PDFPageImageExtractor {
    var images: [NSImage] = []
    
    func extractImages(from page: CGPDFPage) -> [NSImage] {
        self.images = []
        guard let dict = page.dictionary else { return [] }
        
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources) else { return [] }
        
        var xObjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources!, "XObject", &xObjects) else { return [] }
        
        let context = Unmanaged.passUnretained(self).toOpaque()
        
        CGPDFDictionaryApplyBlock(xObjects!, { key, object, info in
            guard let info = info else { return true }
            let extractor = Unmanaged<PDFPageImageExtractor>.fromOpaque(info).takeUnretainedValue()
            
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream) else { return true }
            guard let streamDict = CGPDFStreamGetDictionary(stream!) else { return true }
            
            var subtype: UnsafePointer<Int8>?
            if CGPDFDictionaryGetName(streamDict, "Subtype", &subtype),
               let subtypeName = subtype, String(cString: subtypeName) == "Image" {
                
                var isJPEG = false
                var filter: UnsafePointer<Int8>?
                var filterArray: CGPDFArrayRef?
                
                if CGPDFDictionaryGetName(streamDict, "Filter", &filter),
                   let filterName = filter, String(cString: filterName) == "DCTDecode" {
                    isJPEG = true
                } else if CGPDFDictionaryGetArray(streamDict, "Filter", &filterArray) {
                    var name: UnsafePointer<Int8>?
                    if CGPDFArrayGetName(filterArray!, 0, &name),
                       let n = name, String(cString: n) == "DCTDecode" {
                        isJPEG = true
                    }
                }
                
                if isJPEG {
                    var format: CGPDFDataFormat = .raw
                    guard let data = CGPDFStreamCopyData(stream!, &format) else { return true }
                    if let image = NSImage(data: data as Data) {
                        extractor.images.append(image)
                    }
                }
            }
            return true
        }, context)
        
        return images
    }
}
