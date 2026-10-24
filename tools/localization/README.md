# Übersetzung der Oberfläche

Die App zeigt ihre Oberfläche auf Englisch (Standard) oder Deutsch. Im Code stehen die deutschen Texte,
eingepackt in `L("…")` (Platzhalter wie `L("\(n) Treffer")` funktionieren). Die englischen Fassungen liegen in
`translations-en.json` (Schlüssel: deutscher Text, `%@` für Platzhalter).

- Neue Texte im Code mit `L("…")` schreiben; für Werte aus Daten `L(dynamic: …)`.
- `python3 tools/localization/generate.py` meldet fehlende Übersetzungen und schreibt `EnglishStrings.swift`.
- `wrap.py <Dateien>` packt typische Oberflächentexte automatisch ein (danach den Diff prüfen).

Prompts und Tool-Beschreibungen für das Modell bleiben bewusst Deutsch.
