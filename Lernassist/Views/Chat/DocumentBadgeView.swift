import SwiftUI

// MARK: - DocumentBadgeView

struct DocumentBadgeView: View {
    let message: ChatMessage
    @State private var showPreview = false
    @State private var showProcessingPreview = false

    private var attachment: DocumentAttachment? {
        message.documentAttachment
    }

    var body: some View {
        if let doc = attachment {
            HStack(spacing: 12) {
                // File Icon – während der Verarbeitung zeigt sich hier stattdessen live das
                // Bild (PDF-Seite / eingebettetes Word-Bild), das gerade beschrieben wird.
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.1))
                        .frame(width: 40, height: 40)

                    if doc.status == .processing,
                       let base64 = doc.currentPreviewImageBase64,
                       let data = Data(base64Encoded: base64),
                       let nsImage = NSImage(data: data) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Image(systemName: iconName(for: doc.url))
                            .foregroundColor(.accentColor)
                            .font(.system(size: 20))
                    }
                }

                // Details
                VStack(alignment: .leading, spacing: 4) {
                    Text(doc.url.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    if doc.status == .processing || doc.status == .queued {
                        ProgressView(value: doc.progress, total: 1.0)
                            .progressViewStyle(LinearProgressViewStyle())
                            .frame(height: 4)
                        
                        Text(doc.progressText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if doc.status == .completed {
                        Text("Verarbeitung abgeschlossen")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    } else if doc.status == .failed {
                        Text("Fehler bei der Verarbeitung")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                
                Spacer()
                
                // Actions
                if doc.status == .completed {
                    // Lern-Aktionen direkt aus dem Dokument (Phase H): Karteikarten bzw. Quiz
                    // aus dem extrahierten Text erzeugen – öffnet das Quiz-/Flashcard-Panel und
                    // generiert sofort daraus.
                    Button {
                        NotificationCenter.default.post(name: .studyDocumentRequested, object: nil,
                                                      userInfo: ["text": doc.extractedText, "mode": "flashcards"])
                    } label: {
                        Image(systemName: "rectangle.stack.badge.person.crop")
                            .font(.headline)
                            .foregroundColor(DS.Ink.quiz)
                            .padding(8)
                            .background(Circle().fill(DS.Ink.quiz.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .help("Karteikarten aus diesem Dokument erzeugen")

                    Button {
                        NotificationCenter.default.post(name: .studyDocumentRequested, object: nil,
                                                      userInfo: ["text": doc.extractedText, "mode": "quiz"])
                    } label: {
                        Image(systemName: "checkmark.circle.badge.questionmark")
                            .font(.headline)
                            .foregroundColor(DS.Ink.quiz)
                            .padding(8)
                            .background(Circle().fill(DS.Ink.quiz.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .help("Quiz aus diesem Dokument erzeugen")

                    Button(action: { showPreview = true }) {
                        Image(systemName: "eye")
                            .font(.headline)
                            .foregroundColor(.accentColor)
                            .padding(8)
                            .background(Circle().fill(Color.accentColor.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if doc.status == .completed {
                    showPreview = true
                } else if doc.status == .processing {
                    // War vorher tot: während der Verarbeitung reagierte ein Klick auf gar nichts.
                    showProcessingPreview = true
                }
            }
            .popover(isPresented: $showPreview, arrowEdge: .trailing) {
                DocumentPreviewModal(attachment: doc)
                    .frame(width: 500, height: 600)
            }
            .popover(isPresented: $showProcessingPreview, arrowEdge: .trailing) {
                DocumentProcessingPreviewPopover(attachment: doc)
            }
        } else {
            EmptyView()
        }
    }
    
    private func iconName(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.text.fill"
        case "doc", "docx": return "doc.richtext.fill"
        case "ppt", "pptx": return "chart.bar.doc.fill"
        case "txt", "md": return "doc.plaintext.fill"
        default: return "doc.fill"
        }
    }
}

// MARK: - DocumentProcessingPreviewPopover
// Live-Fortschrittsanzeige während der Verarbeitung: zeigt genau das Bild (PDF-Seite oder
// eingebettetes Word/PowerPoint-Bild), das der Hintergrund-Job gerade per Vision-Modell
// beschreibt, plus Fortschrittsbalken und Statustext. Aktualisiert sich live, da `attachment`
// aus der laufend per @Published aktualisierten Session gespeist wird.

struct DocumentProcessingPreviewPopover: View {
    let attachment: DocumentAttachment

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "hourglass")
                    .foregroundColor(.accentColor)
                Text(attachment.url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let base64 = attachment.currentPreviewImageBase64,
               let data = Data(base64Encoded: base64),
               let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 320, maxHeight: 320)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(width: 320, height: 120)
                    .overlay(ProgressView().controlSize(.small))
            }

            ProgressView(value: attachment.progress, total: 1.0)

            Text(attachment.progressText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 352)
    }
}

// MARK: - DocumentPreviewModal

struct DocumentPreviewModal: View {
    let attachment: DocumentAttachment
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "doc.text.viewfinder")
                    .foregroundColor(.accentColor)
                Text(attachment.url.lastPathComponent)
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Extrahierter Inhalt:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    MarkdownView(markdown: attachment.extractedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .background(Color(NSColor.textBackgroundColor))
        }
    }
}
