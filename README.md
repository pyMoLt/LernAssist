# LernAssist

Ein lokaler, macOS-nativer **Lernassistent** mit Screenshot-Agent. LernAssist nimmt per
globalem Hotkey einen Screenshot auf, schickt ihn an ein **OpenAI-kompatibles KI-Backend**
(LM Studio, Ollama oder OpenAI) und beantwortet Fragen dazu in einem Streaming-Chat –
inklusive Denkprozess-Anzeige, Tool-Calling (lokale Websuche via SearXNG + Browsing),
Markdown/LaTeX-Rendering und mehreren Lernmodi.

Die App ist als **lokales Werkzeug** gedacht (typisch: Zugriff auf den eigenen Rechner via
Tailscale, KI-Modelle in LM Studio) und läuft ohne Cloud-Abhängigkeit.

## Features

- 📸 **Screenshot-Agent** – globaler Hotkey, interaktive Aufnahme, direkt in den Chat
- 🧠 **Streaming-Chat** gegen LM Studio / Ollama / OpenAI-kompatible Endpunkte
- 💭 **Denkprozess-Anzeige** – separate `reasoning`-Felder *und* inline `<think>`-Tags
- 🔧 **Tool-Calling** – Websuche (SearXNG, DuckDuckGo-Fallback) und Webseiten-Browsing
- ✍️ **Markdown, LaTeX & Code-Highlighting** – lokal gerendert (KaTeX, highlight.js)
- 🎓 **Lernmodi** – Anfänger / Detailliert / Prüfungsrelevant, mit anpassbaren Prompts
- ❓ **Lern-Aktionen** – Quiz, „Andere Erklärung", Konfidenz-Einschätzung

## Voraussetzungen

- macOS (Deployment-Target siehe Xcode-Projekt)
- Xcode
- Ein laufendes KI-Backend, z. B. [LM Studio](https://lmstudio.ai) auf `http://127.0.0.1:1234`
- Optional: [SearXNG](https://github.com/searxng/searxng) für die Websuche
  (`docker run -d -p 8080:8080 --name searxng searxng/searxng`)

## Build

```bash
open Lernassist/Lernassist.xcodeproj
# oder
xcodebuild -project Lernassist/Lernassist.xcodeproj -scheme Lernassist build
```

## Projektstruktur

Siehe [AUDIT.md](AUDIT.md) für eine ausführliche Architektur-Übersicht.

## Status

In aktiver Entwicklung. Rein lokales Projekt, keine kommerzielle Nutzung geplant.
