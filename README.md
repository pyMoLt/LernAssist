# LernAssist 3.0

Ein nativer, moderner macOS-Lernassistent (SwiftUI / AppKit) für das Studium (Medizin & Informatik) mit Screenshot-Agent, lokalem KI-Streaming, Spaced Repetition (FSRS-5) und integrierter Recherche- und Coding-Umgebung.

LernAssist nimmt per Tastenkürzel Bildschirmausschnitte auf, sendet sie an lokale oder entfernte KI-Backends (typisch: **oMLX**, **LM Studio**, **Ollama** oder **Apple MLX**) und erklärt Inhalte interaktiv im Chat – inklusive Formeln (KaTeX), Diagrammen (Mermaid), Quellcode-Ausführung (Python), Websuche (SearXNG) und intelligentem Karteikarten-Training.

---

## Funktionen

### 🧠 Intelligenter Chat & Lernmodi
- **Streaming mit voller Transparenz**: Trennung von Prompt-Verarbeitung (Prefill, TTFT) und Token-Generierung (Decode-Speed) mit mitlaufendem Sparkline-Graph.
- **Denkprozess & Arbeitsschritte**: Klappbare Gruppen für Reasoning-Tokens (`<think>`) und Tool-Ausführungen.
- **Didaktische Lernmodi**: Anfänger, Detailliert, Prüfungsrelevant, Sokratisch, Eselsbrücken, ELI5 und Zusammenfassend mit anpassbaren System-Prompts.
- **Automatische Titel & Fach-Etiketten**: Die KI vergibt passende Titel und Fach-Zuordnungen (z. B. *Medizin*, *Informatik*, *Biochemie*), die nach der dritten Frage nachgeschärft werden. In der Seitenleiste kann nach Fächern gefiltert werden.

### 📚 Karteikarten & Fehler-Training (FSRS-5)
- **FSRS-5 Algorithmus**: Moderner Spaced-Repetition-Scheduler (Free Spaced Repetition Scheduler, Standard in Anki/RemNote) mit konfigurierbarer Ziel-Behaltensrate (Standard: 90 %).
- **„Als Karte merken“**: Jede KI-Antwort kann mit einem Klick in 1–3 prüfungsrelevante Karteikarten verdichtet werden (inkl. Undo-Möglichkeit).
- **Interaktive Quizkarten**: Multiple-Choice- und Freitext-Karten direkt im Chatverlauf.
- **Fehlerlog & Training aus Fehlern**: Falsch beantwortete Quizkarten und vergessene Karteikarten landen automatisch im Fehlerlog. Ein Klick startet ein maßgeschneidertes Training zu den Wissenslücken.
- **Karten-Panel**: Schneller Zugriff auf fällige Wiederholungen, Kartensätze und Fehlerhistorie.

### ⚡ Spezial-Befehle (Slash Commands)
- `/quiz [Anzahl] [Thema]`: Generiert interaktive Quizkarten (z. B. `/quiz 5 Citratzyklus`) und wertet diese am Ende aus.
- `/fall [Thema]`: Erstellt interaktive Fallstudien, die sich automatisch an das Fach des Chats anpassen (z. B. klinischer Fall in der Medizin, Systementwurf in der Informatik, Beweis in der Mathematik).
- `/summary [Thema]`: Erstellt einen strukturierten Lernzettel.
- **Export als PDF oder Markdown**: Antworten und Lernzettel können direkt formatiert als A4-PDF (mit Formeln & Mermaid-Diagrammen) oder Markdown gespeichert werden.

### 🛠️ Lokale Werkzeuge & Recherche
- **Python-Coding-Sandbox**: Führt Python-Code lokal und isoliert aus (`uv`-Umgebung mit `numpy`, `matplotlib` etc.), generiert Inline-Plots und visualisiert Daten.
- **Websuche & Quellennachweis**: Lokale Recherche über [SearXNG](https://github.com/searxng/searxng) mit lokalem Reranker (oMLX) und Webseiten-Inhaltsanalyse.
- **Mathematik & Diagramme**: Schnelles Rendering von LaTeX-Formeln (KaTeX) und Flussdiagrammen (Mermaid mit automatischer Hell-/Dunkel-Anpassung).

---

## Architektur & Setup

LernAssist ist auf ein Setup aus zwei Macs ausgelegt:
1. **Server (ein leistungsfähiger Mac)**: Führt das große Sprachmodell lokal aus (z. B. via [oMLX](https://github.com/ml-explore/mlx) auf Port 8072) sowie die SearXNG-Suche (Port 8082).
2. **Client (z. B. ein Laptop unterwegs)**: Verbindet sich über das Netzwerk oder ein VPN (z. B. [Tailscale](https://tailscale.com)) mit dem Server.

### 1. Einrichtungs-Assistent (Setup Assistant)
Beim ersten Start der App (oder jederzeit über **Einstellungen → Erweitert → Assistent starten**) führt ein 5-stufiger Assistent durch die Konfiguration:
- **Rolle wählen**: *Modelle laufen auf diesem Mac* (alles lokal) oder *Remote-Endpunkt nutzen* (Server im Netzwerk).
- **Endpunkt prüfen**: Verbindungs-Diagnose mit Latenz- und Modellabfrage.
- **Websuche / Recherche**: SearXNG-URL eintragen und testen.
- **Systemrechte**: Bildschirmaufnahme und Bedienungshilfen verifizieren.

### 2. Backend-Optionen
- **oMLX** (Empfohlen für Apple Silicon):
  - URL: `http://127.0.0.1:8072` (lokal) oder `http://<tailscale-name>:8072` (remote).
  - Unterstützt Modellwechsel, Vision, Thinking-Budget und Server-seitiges Reranking.
- **LM Studio**:
  - URL: `http://127.0.0.1:1234` (OpenAI-kompatibel oder Native `/api/v0`).
- **Ollama**:
  - URL: `http://127.0.0.1:11434` (Native NDJSON).

---

## Tastenkombinationen (Defaults)

| Aktion | Tastenkürzel | Beschreibung |
|---|---|---|
| **Screenshot aufnehmen** | `⌃ ⇧ L` | Interaktive Bereichsauswahl und direkter Chat-Start |
| **Chat-Fenster öffnen/fokussieren** | `⌃ ⇧ Leertaste` | Schneller Aufruf aus jeder App |
| **Neuer Chat** | `⌘ N` | Leert den Chat und startet eine frische Sitzung |
| **Hauptfenster anzeigen** | `⌘ 0` | Bringt das LernAssist-Hauptfenster in den Vordergrund |
| **Karten wiederholen** | `Leertaste` / `1–4` | Antwort aufdecken und bewerten (1: Nochmal, 2: Schwer, 3: Gut, 4: Einfach) |

*Alle Tastenkürzel können in den Einstellungen (**⌘ , → Hotkeys**) individuell angepasst werden.*

---

## Build & Installation

### Voraussetzungen
- macOS 15.0+ (getestet bis macOS 27)
- Xcode 16+

### Kompilieren
```bash
# Debug-Build & Tests ausführen
xcodebuild test -project Lernassist/Lernassist.xcodeproj -scheme Lernassist -only-testing:LernassistTests -destination 'platform=macOS'

# Release-Build erstellen
xcodebuild -project Lernassist/Lernassist.xcodeproj -scheme Lernassist -configuration Release build
```

### Installation auf einem weiteren Mac
1. Die kompilierte App aus `/Applications/Lernassist.app` als ZIP archivieren:
   ```bash
   ditto -c -k --sequesterRsrc --keepParent /Applications/Lernassist.app ~/Desktop/LernAssist-3.0.zip
   ```
2. Auf das Zielgerät übertragen und in den Programme-Ordner verschieben.
3. **Gatekeeper-Hinweis (Ad-hoc Signatur)**: Da die App privat gebaut wird, muss beim ersten Start entweder über das Kontextmenü (*Rechtsklick → Öffnen*) bestätigt werden oder das Quarantäne-Attribut im Terminal entfernt werden:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Lernassist.app
   ```

---

## Dokumentation & Projektstruktur

- `docs/HANDOVER-2026-10-13-v3.md`: Aktuelle Entwicklungsübergabe und Release-Dokumentation.
- `docs/PLAN-2.0.md` & `docs/PLAN-UI-2.0.md`: Architektur- und Design-Konzepte des Flow-Redesigns.
- `docs/audit/`: Vollständige Audits zu Funktionalität, UI, Sicherheit und Performance.
- `docs/research/`: Rechercheberichte zu Lern-Apps, FSRS, SearXNG und lokalen LLM-Servern.
- `docs/archive/`: Ältere Pläne und Phase-1/2-Dokumente.
- `CHANGELOG.md`: Versionshistorie von 1.0 bis 3.0.

---

## Lizenz & Status

Privates Lern- und Forschungsprojekt für das Studium. Keine externe Cloud-Abhängigkeit, volle Datenhoheit auf den eigenen Geräten.
