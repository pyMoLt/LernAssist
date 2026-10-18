# Changelog

Alle wichtigen Änderungen am Projekt **LernAssist** sind hier dokumentiert.

---

## [3.0] – 2026-10-13

### Neu
- **FSRS-5 Spaced Repetition**: Umstellung der Wiederholungslogik von SM-2 auf den modernen FSRS-5-Algorithmus (Free Spaced Repetition Scheduler). Berechnet Stabilität und Schwierigkeit präzise anhand der gewünschten Ziel-Behaltensrate (konfigurierbar von 80 % bis 97 %, Standard: 90 %). Alte SM-2-Karten werden beim ersten Review automatisch migriert.
- **Karteikarten-Panel**: Zentrales Panel im Chat-Header mit Reitern für *Wiederholen* (mit Tastatursteuerung: Leertaste zum Aufdecken, Tasten 1–4 für Bewertung), *Alle Karten* und *Fehlerlog*.
- **„Als Karte merken“**: KI-Antworten und beantwortete Quizkarten können mit einem Klick in 1 bis 3 prüfungsrelevante Karteikarten verdichtet werden – mit sofortigem Rückgängig-Hinweis.
- **Fehlerlog & Training aus Fehlern**: Falsch beantwortete Quizfragen und vergessene Karten landen automatisch in `mistakes.json`. Ein Klick im Fehlerlog startet einen maßgeschneiderten Übungschat zu den offenen Wissenslücken.
- **Spezial-Befehle (Slash Commands)**:
  - `/quiz [Anzahl] [Thema]`: Generiert die angegebene Anzahl an Quizkarten (Multiple Choice oder Freitext) mit abschließender Lernauswertung.
  - `/fall [Thema]`: Interaktive Fallaufgabe, die sich adaptiv an das Fach des Chats anpasst (z. B. klinischer Patientenfall für Medizin, Softwarearchitektur für Informatik, Beweisaufgabe für Mathe).
  - `/summary [Thema]`: Kompakter, strukturierter Lernzettel.
- **Lernzettel-Export (PDF & Markdown)**: Jede Antwort kann direkt formatiert als A4-PDF (mit KaTeX-Formeln und Mermaid-Diagrammen) oder Markdown gespeichert werden. Robuster WebKit-Drucker mit Fallback auf native PDF-Rohdaten.
- **KI-Titel & Fach-Etiketten**: Die KI vergibt nach der ersten Antwort automatisch einen prägnanten Titel (2–4 Wörter) und ein Fach-Etikett (z. B. *Medizin*, *Informatik*, *Physiologie*). Nach der dritten Frage wird beides anhand des Kontextes nachgeschärft.
- **Seitenleisten-Filter nach Fach**: Schnelles Filtern aller Chats nach Studienfach und Zuweisen per Rechtsklick.
- **Einrichtungs-Assistent (Setup Assistant)**: 5-stufiger Wizard beim ersten Start (oder über Einstellungen → Erweitert) zur Wahl der Rolle (*Server* vs. *Client* über Tailscale), Endpunkt-Prüfung, Recherche-Konfiguration und Berechtigungs-Check.
- **Info-Modus in den Einstellungen**: Kleiner Info-Schalter („i“) oben rechts schaltet didaktische Tooltipps und Erklärungen für jede Einstellungszeile frei.
- **Dynamisches Mermaid-Theme**: Wechsel zwischen Hell- und Dunkelmodus rendert Mermaid-Flussdiagramme ohne Seitenreload mit angepasster Farbpalette neu.

### Verbessert
- **Kompakte Telemetrie**: Bei schmalem Fenster schrumpft die Metriken-Kapsel automatisch auf die zwei Kernwerte (⚡Prefill-Speed · Decode-Speed).
- **Zweizeiliger Chat-Header**: Vollständiger Chat-Titel in voller Breite oben, Umschalter und Telemetrie-Kapsel übersichtlich in Zeile 2.
- **Aktionsleiste unter Antworten**: Sanftes Ausblenden bei Nicht-Hover ohne Layout-Verschiebung; einheitliche, ruhige monochrome Gestaltung.
- **Swift 6 & Accessibility**: Behebung von rund 40 Swift-6-Concurrency-Warnungen und Ergänzung von VoiceOver-Labels für alle Steuerungs-Buttons.

---

## [2.0] – 2026-10-13

### Neu
- **Flow-Designsprache (DS 2.0)**: Vollständige Überarbeitung der Oberflächen. Rahmenlose, organisch ineinanderfließende Elemente ohne harte 1px-Kontrastränder unter macOS.
- **Vektor-App-Icon (`LernAssistBrandIcon`)**: Neues Markensymbol (Indigo-Violett-Gradient, Viewfinder-Rahmen, Glas-Innenkapsel, weiße Doktorhut-Silhouette mit goldener Quaste) integriert in Sidebar, Header, Welcome-Screen und Avataren.
- **Live-Telemetrie & Sparkline-Graph**:
  - Exakte Unterscheidung zwischen Prompt Processing (Prefill / TTFT) und Token Speed (Decode).
  - 5-Hz-Live-Sparkline im Header und großes Verlaufschart im Telemetrie-Popover.
  - Schneller Modell- und Server-Umschalter direkt im Popover.
- **Direkte Modell-Auswahl nach Server-Ping**: Endpunkte- und Modell-Tabs zeigen nach einem erfolgreichen Ping alle vom Server bereitgestellten Modelle direkt im gleichen Eingabefeld als Ausklapp-Menü.
- **Lokale Python-Coding-Sandbox**: Sichere Ausführung von Python-Code (`uv`, `matplotlib`, `numpy`) mit direkter Darstellung von Plot-Grafiken im Chatverlauf.
- **Lokale Recherche via SearXNG**: Web-Suche ohne externe Tracking-Dienste, inklusive Inhaltsabruf und lokalem oMLX-Reranker.
- **Arbeitsschritte-Gruppierung (WorkSteps)**: Denkprozess, Notizen und Tool-Aufrufe werden während des Streamings in einer klappbaren Gruppe zusammengefasst.
- **Archiv- & Papierkorb-Browser**: Eigenes Verwaltungsfenster für archivierte und gelöschte Sitzungen mit Vorschau und Wiederherstellung.

---

## [1.0] – 2026-09-20

### Initiales Release
- Screenshot-Agent mit interaktiver Bereichsauswahl per Hotkey (`⌃ ⇧ L`).
- Streaming-Chat gegen OpenAI-kompatible Server, LM Studio und Ollama.
- Rendering von Markdown, LaTeX (KaTeX) und Syntax-Highlighting (highlight.js).
- Didaktische Lernmodi (Anfänger, Detailliert, Prüfungsrelevant).
- Multiple-Choice-Quiz und grundlegende SM-2-Karteikarten.
- Menüleisten-Modus und persistente Speicherung der Sitzungen.
