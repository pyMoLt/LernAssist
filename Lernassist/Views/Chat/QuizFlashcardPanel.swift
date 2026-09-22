import SwiftUI
import os

struct QuizFlashcardPanel: View {
    /// Bewusst KEIN @ObservedObject (Audit U13): Das Panel hat eigene lokale @State-Daten
    /// (quizMessages, Flashcard-State) und braucht das ViewModel nur für Methodenaufrufe und
    /// Momentaufnahmen. Als Observer re-renderete das komplette Panel bei JEDEM Token des
    /// Haupt-Chats, solange es offen war. Der Datenstand wird beim Öffnen sowie nach eigenen
    /// Aktionen (die lokale @State mutieren) aktualisiert – live nachgezeichnet werden muss
    /// hier nichts.
    var viewModel: ChatViewModel
    @Environment(\.dismiss) var dismiss
    
    @State private var selectedTab = 0 // 0 = Quiz, 1 = Flashcards, 2 = Fällig heute (global)
    /// Dokument-Seed (Phase H): Wenn gesetzt, generiert das Panel Quiz bzw. Karteikarten direkt
    /// aus diesem Text (aus dem Dokument-Badge gestartet) statt aus dem Chat-Kontext.
    var studySeed: (text: String, mode: String)? = nil
    @State private var isDueCardFlipped = false
    
    // Quiz/Flashcard Settings
    @State private var difficulty = "Mittel"
    @State private var customInstructions = ""
    
    // Quiz State
    @State private var quizMessages: [ChatMessage] = []
    @State private var quizInput = ""
    @State private var isGenerating = false
    
    // Flashcard State
    @State private var flashcards: [Flashcard] = []
    @State private var currentFlashcardIndex = 0
    @State private var isFlipped = false
    @State private var flashcardCount = 5
    @State private var isGeneratingFlashcards = false
    @State private var flashcardErrorText: String?
    @State private var selectedFlashcardSetID: UUID?
    
    var session: ChatSession? { viewModel.activeSession }
    
    private var imageCount: Int {
        session?.messages.filter { $0.imageBase64 != nil }.count ?? 0
    }
    private var textMessageCount: Int {
        session?.messages.count ?? 0
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "checkmark.circle.badge.questionmark")
                    .foregroundColor(.purple)
                Text("Quiz & Karteikarten")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Context Overview & Settings
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Thema: \(session?.title ?? "Unbekannt")")
                            .font(.headline)
                        Text("Kontext: \(textMessageCount) Nachrichten, \(imageCount) Bilder")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    
                    Picker("Schwierigkeit", selection: $difficulty) {
                        Text("Leicht").tag("Leicht")
                        Text("Mittel").tag("Mittel")
                        Text("Schwer").tag("Schwer")
                    }.frame(width: 150)
                }
                
                TextField("Zusätzliche Anweisungen (z.B. Sokratischer Stil)", text: $customInstructions)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if selectedTab == 0 && quizMessages.isEmpty {
                            startQuiz()
                        } else if selectedTab == 1 && flashcards.isEmpty {
                            generateFlashcards()
                        }
                    }
            }
            .padding()
            .background(Color.primary.opacity(0.03))
            
            Divider()
            
            // Tabs
            Picker("", selection: $selectedTab) {
                Text("Quiz-Modus").tag(0)
                Text("Karteikarten").tag(1)
                Text(viewModel.dueFlashcardsCount > 0 ? "Fällig heute (\(viewModel.dueFlashcardsCount))" : "Fällig heute").tag(2)
            }
            .pickerStyle(.segmented)
            .padding()

            if selectedTab == 0 {
                quizView
            } else if selectedTab == 1 {
                flashcardView
            } else {
                dueReviewView
            }
        }
        .frame(width: 700, height: 600)
        .onAppear {
            // Dokument-Seed (Phase H): Direkt aus einem Dokument geöffnet → passenden Tab
            // wählen und die Generierung sofort anstoßen.
            if let seed = studySeed {
                selectedTab = seed.mode == "flashcards" ? 1 : 0
                if seed.mode == "flashcards" {
                    generateFlashcards()
                } else {
                    startQuiz()
                }
                return
            }
            // Beim Öffnen direkt auf "Fällig heute" springen, wenn Karten warten – das ist genau
            // die Erinnerung, die beim Öffnen des Panels sichtbar werden soll, statt sie hinter
            // dem Standard-Tab zu verstecken.
            if viewModel.dueFlashcardsCount > 0 {
                selectedTab = 2
            }
            // Bereits für diesen Chat erzeugte Karteikarten laden – vorher startete das Panel
            // bei jedem Öffnen mit einer leeren Liste, selbst wenn schon welche generiert und
            // gespeichert wurden (waren dann faktisch nirgends mehr abrufbar).
            if flashcards.isEmpty, let existing = session?.flashcards, !existing.isEmpty {
                flashcards = existing
            }
        }
    }
    
    // MARK: - Quiz View
    private var quizView: some View {
        VStack {
            if quizMessages.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 40))
                        .foregroundColor(.purple)
                    Text("Starte das interaktive Quiz basierend auf deinem aktuellen Chat.")
                        .foregroundColor(.secondary)
                    
                    Button("Quiz starten") {
                        startQuiz()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(quizMessages) { msg in
                            // .equatable() (Perf-Audit K1): aktiviert den MessageBubble-Diffing
                            // auch im Quiz-Panel.
                            MessageBubble(message: msg, chatViewModel: viewModel, isStreaming: isGenerating && msg.id == quizMessages.last?.id, fontScale: viewModel.chatFontSize)
                                .equatable()
                        }
                    }
                    .padding()
                }
                
                Divider()
                
                HStack {
                    TextField("Antwort oder Rückfrage eingeben...", text: $quizInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(sendQuizMessage)
                    
                    Button(action: sendQuizMessage) {
                        Image(systemName: "paperplane.fill")
                    }
                    .disabled(quizInput.isEmpty || isGenerating)
                }
                .padding()
            }
        }
    }    // MARK: - Flashcard View
    private var flashcardView: some View {
        HStack(spacing: 0) {
            // Sidebar: Local Sets
            VStack(alignment: .leading, spacing: 0) {
                Text("Meine Sets")
                    .font(.headline)
                    .padding()
                
                List(selection: $selectedFlashcardSetID) {
                    Section("Aktionen") {
                        HStack {
                            Image(systemName: "plus.square.dashed")
                                .foregroundColor(.blue)
                            Text("Neues Set generieren")
                        }
                        .tag(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!) // Magic ID
                    }
                    
                    if let sets = session?.flashcardSets, !sets.isEmpty {
                        Section("Gespeicherte Sets") {
                            ForEach(sets) { set in
                                HStack {
                                    Image(systemName: "folder.fill")
                                        .foregroundColor(.blue)
                                    VStack(alignment: .leading) {
                                        Text(set.title)
                                            .font(.subheadline)
                                            .lineLimit(1)
                                        Text("\(set.cards.count) Karten")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .tag(set.id)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        deleteFlashcardSet(set.id)
                                    } label: {
                                        Label("Set löschen", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(width: 250)
            
            Divider()
            
            // Detail View
            VStack {
                if selectedFlashcardSetID == UUID(uuidString: "00000000-0000-0000-0000-000000000000") {
                    flashcardGenerationUI
                } else if let set = session?.flashcardSets?.first(where: { $0.id == selectedFlashcardSetID }) {
                    flashcardLearningUI(for: set)
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("Wähle ein Set aus oder erstelle ein neues.")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if selectedFlashcardSetID == nil {
                selectedFlashcardSetID = session?.flashcardSets?.first?.id ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            }
            updateLocalFlashcardState()
        }
        .onChange(of: selectedFlashcardSetID) { _ in
            updateLocalFlashcardState()
        }
    }
    
    private func deleteFlashcardSet(_ setId: UUID) {
        guard let sessionId = session?.id else { return }
        viewModel.deleteFlashcardSet(sessionId: sessionId, setId: setId)
        // War das gelöschte Set gerade ausgewählt, zurück auf "Neues Set generieren" springen,
        // statt auf ein jetzt nicht mehr existierendes Set zu zeigen.
        if selectedFlashcardSetID == setId {
            selectedFlashcardSetID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            updateLocalFlashcardState()
        }
    }

    private func updateLocalFlashcardState() {
        currentFlashcardIndex = 0
        isFlipped = false
        if let set = session?.flashcardSets?.first(where: { $0.id == selectedFlashcardSetID }) {
            flashcards = set.cards
        } else {
            flashcards = []
        }
    }
    
    private var flashcardGenerationUI: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled")
                .font(.system(size: 40))
                .foregroundColor(.blue)
            Text("Generiere Karteikarten aus dem aktuellen Kontext.")
                .foregroundColor(.secondary)
            
            HStack {
                Text("Anzahl:")
                Picker("", selection: $flashcardCount) {
                    Text("5").tag(5)
                    Text("10").tag(10)
                    Text("15").tag(15)
                    Text("20").tag(20)
                }.frame(width: 80)
            }

            Button("Karteikarten generieren") {
                generateFlashcards()
            }
            .buttonStyle(.borderedProminent)
            .disabled(isGeneratingFlashcards)
            
            if isGeneratingFlashcards {
                ProgressView("Generiere Karteikarten...")
                    .padding()
            }
            // Sichtbares Fehler-Feedback statt stiller print + verschwindendem Spinner (Audit U9):
            // Der Nutzer bekam bei unparsebarer JSON-Karteikarten keinerlei Erklärung.
            if let err = flashcardErrorText {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
            }
            Spacer()
        }
    }
    
    private func flashcardLearningUI(for set: FlashcardSet) -> some View {
        VStack(spacing: 20) {
            Text(set.title)
                .font(.headline)
                .padding(.top)
                
            Spacer()
            
            if !flashcards.isEmpty && currentFlashcardIndex < flashcards.count {
                // Flashcard Card
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .shadow(radius: 4)

                    // Vorher rotierte der Text hier ein zweites Mal um denselben Winkel wie der
                    // äußere ZStack (doppelt gestapelte rotation3DEffects) → der Text drehte sich
                    // effektiv doppelt so schnell wie die Karte selbst, was schwindelig macht.
                    // Jetzt: Vorder-/Rückseite sind zwei separate Texte, die per Opacity ein-/
                    // ausgeblendet werden; nur die Rückseite bekommt eine fixe 180°-Gegendrehung,
                    // damit ihr Text nach der Kartendrehung wieder normal lesbar (nicht gespiegelt)
                    // erscheint – die Karte selbst dreht sich dabei nur noch genau einmal.
                    Text(flashcards[currentFlashcardIndex].front)
                        .font(.title2)
                        .multilineTextAlignment(.center)
                        .padding()
                        .opacity(isFlipped ? 0 : 1)

                    Text(flashcards[currentFlashcardIndex].back)
                        .font(.title2)
                        .multilineTextAlignment(.center)
                        .padding()
                        .opacity(isFlipped ? 1 : 0)
                        .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                }
                .frame(width: 400, height: 250)
                .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
                .onTapGesture {
                    withAnimation(.spring()) {
                        isFlipped.toggle()
                    }
                }
                
                Text("Klicke auf die Karte zum Umdrehen")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 40) {
                    Button("Vorherige") {
                        if currentFlashcardIndex > 0 {
                            isFlipped = false
                            currentFlashcardIndex -= 1
                        }
                    }
                    .disabled(currentFlashcardIndex == 0)
                    
                    Text("\(currentFlashcardIndex + 1) / \(flashcards.count)")
                    
                    Button("Nächste") {
                        if currentFlashcardIndex < flashcards.count - 1 {
                            isFlipped = false
                            currentFlashcardIndex += 1
                        }
                    }
                    .disabled(currentFlashcardIndex == flashcards.count - 1)
                }
            } else {
                Text("Keine Karten geladen.")
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
    
    // MARK: - Fällig heute (globales Spaced-Repetition-System)
    // Sammelt Karteikarten aus JEDEM Chat (aktiv + archiviert, siehe
    // ChatViewModel.dueFlashcards) statt nur aus dem aktuellen – so wird nicht pro Chat einzeln
    // wiederholt, sondern alles Fällige an einem Ort abgearbeitet.

    private var dueReviewView: some View {
        let due = viewModel.dueFlashcards
        return VStack(spacing: 20) {
            if due.isEmpty {
                Spacer()
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.green)
                Text("Keine Karten fällig – alles erledigt! 🎉")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                let current = due[0]

                Text("\(due.count) Karte\(due.count == 1 ? "" : "n") fällig")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(current.sessionTitle)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(4)
                    .foregroundColor(.secondary)

                Spacer()

                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .shadow(radius: 4)

                    // Siehe flashcardLearningUI: getrennte Vorder-/Rückseiten-Texte statt einer
                    // doppelt rotierten Text-View, damit der Text nicht doppelt so schnell wie die
                    // Karte dreht und die Rückseite nach dem Flip nicht gespiegelt erscheint.
                    Text(current.card.front)
                        .font(.title2)
                        .multilineTextAlignment(.center)
                        .padding()
                        .opacity(isDueCardFlipped ? 0 : 1)

                    Text(current.card.back)
                        .font(.title2)
                        .multilineTextAlignment(.center)
                        .padding()
                        .opacity(isDueCardFlipped ? 1 : 0)
                        .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                }
                .frame(width: 400, height: 250)
                .rotation3DEffect(.degrees(isDueCardFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
                .onTapGesture {
                    withAnimation(.spring()) { isDueCardFlipped.toggle() }
                }

                if isDueCardFlipped {
                    HStack(spacing: 10) {
                        ForEach(FlashcardRating.allCases) { rating in
                            Button(rating.label) {
                                viewModel.recordFlashcardReview(
                                    sessionId: current.sessionId, setId: current.setId,
                                    cardId: current.card.id, rating: rating
                                )
                                isDueCardFlipped = false
                            }
                            .buttonStyle(.bordered)
                            .tint(ratingColor(rating))
                        }
                    }
                } else {
                    Text("Klicke auf die Karte, um sie umzudrehen und zu bewerten")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
        }
    }

    private func ratingColor(_ rating: FlashcardRating) -> Color {
        switch rating {
        case .again: return .red
        case .hard:  return .orange
        case .good:  return .green
        case .easy:  return .blue
        }
    }

    // MARK: - Actions
    
    private func startQuiz() {
        // Perf-Audit L3: onSubmit kann eine zweite Generierung starten, während die erste
        // noch läuft (quizMessages ist bis zum Ergebnis leer) – Guard verhindert Parallelläufe.
        guard !isGenerating else { return }
        let history = buildContextString()
        let prompt = """
Wir führen nun ein interaktives Quiz durch.
Thema/Kontext des Chats:
\(history)

Anweisungen:
- Stelle mir basierend auf dem obigen Kontext 1-3 Fragen.
- Schwierigkeitsgrad: \(difficulty)
- Zusätzliche Anweisungen: \(customInstructions.isEmpty ? "Keine" : customInstructions)
- Warte auf meine Antwort, bevor du auflöst.
- Sei motivierend und erkläre Fehler.
"""
        let instructionText = customInstructions.isEmpty ? "Lass uns ein Quiz starten." : "Erstelle Quiz: \(customInstructions)"
        quizMessages.append(ChatMessage(role: "user", content: instructionText))
        quizMessages.append(ChatMessage(role: "assistant", content: "")) // Placeholder
        isGenerating = true
        
        Task {
            let result = await viewModel.sendInvisiblePrompt(prompt, context: [])
            await MainActor.run {
                quizMessages[quizMessages.count - 1].content =
                    result ?? "Antwort konnte nicht generiert werden (Netzwerk-/Endpoint-Fehler)."
                isGenerating = false
            }
        }
    }

    private func sendQuizMessage() {
        // Audit H10: Ohne diesen Guard wurde eine Folgefrage während laufender Quiz-Antwort
        // angenommen: die neue Antwort schrieb in den Placeholder der NOCH laufenden alten
        // Runde und landete so in der falschen Bubble. Wie startQuiz/generateFlashcards
        // (Perf-Audit L3) gilt: keine parallele Doppelgenerierung.
        guard !isGenerating else { return }
        guard !quizInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = quizInput
        quizInput = ""
        quizMessages.append(ChatMessage(role: "user", content: text))
        quizMessages.append(ChatMessage(role: "assistant", content: ""))
        isGenerating = true
        
        // Letzte X Nachrichten an das Modell schicken (ohne Bilder für Performance)
        let context = Array(quizMessages.dropLast()) // alles bis auf den Placeholder
        
        Task {
            let result = await viewModel.sendInvisiblePrompt(text, context: context)
            await MainActor.run {
                quizMessages[quizMessages.count - 1].content =
                    result ?? "Antwort konnte nicht generiert werden (Netzwerk-/Endpoint-Fehler)."
                isGenerating = false
            }
        }
    }
    
    private func generateFlashcards() {
        let history = buildContextString()
        let prompt = """
Erstelle \(flashcardCount) Karteikarten aus dem folgenden Kontext.
Schwierigkeitsgrad: \(difficulty)
Zusätzliche Anweisungen: \(customInstructions.isEmpty ? "Keine" : customInstructions)

Kontext:
\(history)

Du musst strikt mit einem JSON-Array antworten, ohne Markdown-Blöcke (kein ```json).
Formatbeispiel:
[
  {"front": "Frage 1", "back": "Antwort 1"},
  {"front": "Frage 2", "back": "Antwort 2"}
]
"""
        // Perf-Audit L3: wie startQuiz – keine parallele Doppelgenerierung.
        guard !isGeneratingFlashcards else { return }
        isGeneratingFlashcards = true
        flashcardErrorText = nil // alte Fehlermeldung beim erneuten Versuch zurücksetzen
        Task {
            guard let result = await viewModel.sendInvisiblePrompt(prompt, context: []) else {
                await MainActor.run {
                    flashcardErrorText = "Karteikarten konnten nicht erzeugt werden – Endpunkt nicht erreichbar. Bitte erneut versuchen."
                    self.isGeneratingFlashcards = false
                }
                return
            }

            // Weit ausführlicheres JSON Parsing mit Regex und Reparatur
            var jsonString = result
            
            // 1. Extrahiere den Array-Block mit Regex (ignoriert jeglichen Text davor/danach)
            if let regex = try? NSRegularExpression(pattern: "\\[.*\\]", options: [.dotMatchesLineSeparators]),
               let match = regex.firstMatch(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count)) {
                if let swiftRange = Range(match.range, in: result) {
                    jsonString = String(result[swiftRange])
                }
            }
            
            // 2. Repariere häufige LLM-JSON-Fehler (z.B. Komma vor der schließenden Klammer)
            jsonString = jsonString.replacingOccurrences(of: ",\\s*]", with: "]", options: .regularExpression)
            // 3. Sichere Entfernung von Markdown-Resten im Array-Block
            jsonString = jsonString.replacingOccurrences(of: "```json", with: "")
            jsonString = jsonString.replacingOccurrences(of: "```", with: "")
            
            if let data = jsonString.data(using: .utf8),
               let cards = try? JSONDecoder().decode([Flashcard].self, from: data) {
                await MainActor.run {
                    self.flashcards = cards
                    self.isGeneratingFlashcards = false
                    if let sessionId = viewModel.activeSession?.id {
                        let formatter = DateFormatter()
                        formatter.dateStyle = .short
                        formatter.timeStyle = .short
                        let newSet = FlashcardSet(title: "Set vom \(formatter.string(from: Date()))", cards: cards)
                        
                        var existingSets = viewModel.activeSession?.flashcardSets ?? []
                        existingSets.insert(newSet, at: 0)
                        
                        viewModel.updateFlashcardSets(for: sessionId, sets: existingSets)
                        self.selectedFlashcardSetID = newSet.id
                        self.updateLocalFlashcardState()
                    }
                }
            } else {
                // Sichtbares Feedback statt print (Audit U9): Der Spinner verschwand einfach,
                // ohne dass der Nutzer wusste, dass und warum die Generierung scheiterte.
                AppLog.tools.error("JSON Parsing der Flashcards fehlgeschlagen: \(result)")
                await MainActor.run {
                    flashcardErrorText = "Karteikarten konnten nicht erzeugt werden – die Modell-Antwort war kein gültiges JSON. Bitte erneut versuchen."
                    self.isGeneratingFlashcards = false
                }
            }
        }
    }
    
    private func buildContextString() -> String {
        // Dokument-Seed (Phase H): Quiz/Karten aus einem konkreten Dokument – der Seed-Text
        // ersetzt den Chat-Kontext (mit demselben Längen-Limit pro Segment wie bisher).
        if let seed = studySeed {
            return String(seed.text.prefix(12_000))
        }
        guard let session = session else { return "" }
        return session.messages
            .filter { $0.role != "system" }
            .map { "[\($0.role)]: \($0.content.prefix(1000))" }
            .joined(separator: "\n")
    }
}
