# App-Icon LernAssist 2.0 

**Idee:** Sucher-Rahmen (Screenshot aufnehmen) um ein Glas-Plättchen mit Doktorhut (lernen), auf einem Verlauf
von Violett nach Indigo (Akzentfarbe der App).

| Datei | Ebene (Icon Composer) |
|---|---|
| `1_background.svg` | Hintergrund (Verlauf + Lichtpunkt) |
| `2_viewfinder.svg` | Ebene 1 – Sucher-Ecken (opak, weiß) |
| `3_glass_cap.svg` | Ebene 2 – Glas-Plättchen + Doktorhut (in Icon Composer mit Glas/Transluzenz) |
| `preview_flat.svg` / `preview_1024.png` | Flache Vorschau im macOS-Raster (824 px, Radius 185, Schatten) |

`scripts/make_icons.sh` rendert `preview_flat.svg` in alle Größen von `AppIcon.appiconset`.
Für echte Liquid-Glass-Effekte: In Icon Composer ein `.icon` aus den drei Ebenen anlegen und als `AppIcon` ins Target legen.
