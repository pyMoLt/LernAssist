import SwiftUI

struct ChatScreenshotPanel: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) var dismiss
    
    var session: ChatSession? {
        viewModel.activeSession
    }
    
    // Filtert auf `imageID` statt `imageBase64` – siehe ausführlicher Kommentar in
    // ScreenshotGalleryView.allImages: `imageBase64` ist bei aus einer vorherigen Session
    // wiederhergestellten Nachrichten immer nil (wird von SessionStore bewusst nicht persistiert),
    // nur `imageID` überlebt einen Neustart.
    private var chatImages: [ChatMessage] {
        session?.messages.filter { $0.imageID != nil } ?? []
    }
    
    let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "photo.stack")
                    .foregroundStyle(DS.Ink.accent)
                Text("Bilder dieses Chats")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            let images = chatImages
            if images.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "photo")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Noch keine Screenshots in diesem Chat vorhanden.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(images, id: \.id) { msg in
                            // Ohne viewModel-Referenz (Audit U13): Die Zelle brauchte das
                            // @ObservedObject nie – mit ihm re-renderierte JEDE Zelle bei jedem
                            // eingehenden Token des Haupt-Chats (Re-Render-Sturm, solange das
                            // Panel offen ist).
                            ChatImageCell(message: msg, dismiss: dismiss)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 380, idealWidth: 500, maxWidth: 500, minHeight: 300, idealHeight: 400, maxHeight: 400)
    }
}

private struct ChatImageCell: View {
    let message: ChatMessage
    var dismiss: DismissAction
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let imgID = message.imageID {
                OptimizedImageView(imageID: imgID, base64: message.imageBase64)
                    .frame(height: 100)
                    .cornerRadius(6)
                    .clipped()
            }
            
            // Echter Bild-zu-Text-Status (ChatViewModel.describeImage), nicht mehr das
            // unabhängige message.content-Feld, das hier vorher fälschlich als Proxy diente.
            HStack {
                Circle()
                    .fill(message.imageDescription != nil ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(message.imageDescription != nil ? "Beschrieben" : "Noch nicht verarbeitet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            Divider()
            
            // Aktionen
            HStack(spacing: 8) {
                Button(action: { Task { await copyImage() } }) {
                    Image(systemName: "doc.on.doc")
                }
                .help("Bild kopieren")

                Button(action: { Task { await askQuestion() } }) {
                    Image(systemName: "questionmark.bubble")
                }
                .help("Rückfrage stellen")
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(DS.Ink.accent)
        }
        .padding(8)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(8)
    }

    /// Lädt das NSImage entweder direkt aus `imageBase64` (frisch in dieser Session angehängt)
    /// oder – für aus einem früheren App-Start wiederhergestellte Nachrichten, deren `imageBase64`
    /// beim Persistieren bewusst entfernt wurde (siehe SessionStore) – per `imageID` von Platte.
    private func resolveImage() async -> NSImage? {
        if let b64 = message.imageBase64, let data = Data(base64Encoded: b64), let img = NSImage(data: data) {
            return img
        }
        guard let imgID = message.imageID else { return nil }
        return await ImageStore.shared.loadFromDisk(for: imgID)
    }

    private func copyImage() async {
        guard let nsImage = await resolveImage() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([nsImage])
    }

    private func askQuestion() async {
        // Kopiert das Bild virtuell in die InputArea oder sendet einen direkten Prompt.
        // Für diesen Prototyp können wir das Bild in die Zwischenablage legen und den User
        // auffordern Cmd+V zu drücken, ODER idealerweise das Bild direkt als "lastCapturedImage" im ChatView setzen.
        // Da wir keinen direkten Zugriff auf "lastCapturedImage" haben, feuern wir eine Notification:
        guard let nsImage = await resolveImage() else { return }
        NotificationCenter.default.post(name: .externalScreenshotCaptured, object: nsImage)
        dismiss()
    }
}
