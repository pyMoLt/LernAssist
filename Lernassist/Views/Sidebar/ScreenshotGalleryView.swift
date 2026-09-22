import SwiftUI

struct ScreenshotGalleryView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) var dismiss
    
    // Wir sammeln alle Screenshots nur aus aktuellen (nicht archivierten) Chats.
    // Filtert auf `imageID` statt `imageBase64`: SessionStore.save() entfernt `imageBase64` bewusst
    // aus der persistierten JSON (nur `imageID` + PNG auf Platte bleiben erhalten, siehe
    // SessionStore-Kommentar). Nach einem Neustart ist `imageBase64` bei allen wiederhergestellten
    // Nachrichten NIL – ein Filter auf `imageBase64 != nil` hätte den Screenshot-Pool nach jedem
    // Neustart faktisch leer gezeigt, obwohl die Bilder (per imageID) weiterhin verfügbar sind.
    private var allImages: [(session: ChatSession, message: ChatMessage)] {
        var results: [(ChatSession, ChatMessage)] = []
        for session in viewModel.sessions {
            for msg in session.messages where msg.imageID != nil {
                results.append((session, msg))
            }
        }
        // Neueste zuerst
        return results.reversed()
    }
    
    let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "photo.on.rectangle.angled")
                    .foregroundColor(.blue)
                Text("Screenshot-Pool")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            let images = allImages
            if images.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "photo")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("Noch keine Screenshots vorhanden.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(images, id: \.message.id) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                if let imgID = item.message.imageID {
                                    OptimizedImageView(imageID: imgID, base64: item.message.imageBase64)
                                        .frame(height: 100)
                                        .cornerRadius(6)
                                        .clipped()
                                }
                                Text(item.session.title)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .foregroundColor(.secondary)
                            }
                            .padding(8)
                            .background(Color.primary.opacity(0.05))
                            .cornerRadius(8)
                            .onTapGesture {
                                // Könnte den Chat öffnen und zum Bild springen
                                if !viewModel.sessions.contains(where: { $0.id == item.session.id }) {
                                    viewModel.unarchiveSession(id: item.session.id)
                                }
                                viewModel.activeSessionId = item.session.id
                                dismiss()
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(width: 600, height: 500)
    }
}
