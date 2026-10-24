"""Erzeugt Lernassist/Views/Settings/SettingsSearchIndex.swift: alle Einstellungen (Zeilen, Abschnitte,
Feldnamen) mit Reiter und ggf. aufklappbarem Abschnitt – Grundlage der Suche in den Einstellungen.

    python3 tools/settings-search/generate_index.py
"""
import os, re, sys
here = os.path.dirname(os.path.abspath(__file__))
app = os.path.join(here, '..', '..', 'Lernassist')
sys.path.insert(0, os.path.join(here, '..', 'localization'))
from wrap import scan_literal
from extract import key_of

TABS = {
    'EndpointsTabView': 'endpoints', 'ModelTabView': 'model', 'ModelsTabView': 'models',
    'LearningModeTabView': 'learning', 'SearchTabView': 'search', 'ToolsTabView': 'tools',
    'HotkeysTabView': 'hotkeys', 'AdvancedTabView': 'advanced', 'StorageLocationsSection': 'advanced',
    'AppearanceTabView': 'appearance',
}

def block_end(s, start):
    """Ende des Blocks, der mit dem ersten '{' ab start beginnt."""
    i = s.find('{', start)
    depth = 0
    while i < len(s):
        c = s[i]
        if c == '"':
            e = scan_literal(s, i)
            i = e if e else i + 1
            continue
        if c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0: return i
        i += 1
    return len(s)

def literal_after(s, pos):
    m = re.compile(r'\s*L\(\s*(?=")').match(s, pos)
    if not m: return None
    e = scan_literal(s, m.end())
    return key_of(s[m.end():e]) if e else None

entries = []
for name, tab in TABS.items():
    path = os.path.join(app, 'Views', 'Settings', name + '.swift')
    if not os.path.exists(path): continue
    s = open(path).read()
    sections = []
    for m in re.finditer(r'SettingsDisclosureSection\(\s*title:', s):
        title = literal_after(s, m.end())
        if title: sections.append((m.start(), block_end(s, m.end()), title))
    def section_of(pos):
        inner = [t for (a, b, t) in sections if a < pos < b]
        return inner[-1] if inner else None
    for m in re.finditer(r'\b(SettingsRow\(\s*title:|settingsSection\(icon:\s*"[^"]*",\s*title:|labeledField\(|SettingsDisclosureSection\(\s*title:)', s):
        title = literal_after(s, m.end())
        if not title or '%@' in title: continue
        subtitle = None
        sub = re.compile(r'\)?\s*,\s*subtitle:').match(s, m.end() + 0)
        rest = s[m.end():m.end() + 2000]
        sm = re.search(r'^\s*L\("(?:[^"\\]|\\.)*"\)\s*,\s*subtitle:', rest)
        if sm:
            subtitle = literal_after(s, m.end() + sm.end())
        kind = 'section' if m.group(1).startswith(('settingsSection', 'SettingsDisclosure')) else 'row'
        entries.append((tab, kind, title, subtitle or '', section_of(m.start()) if kind == 'row' else None))

seen = set(); unique = []
for e in entries:
    k = (e[0], e[2])
    if k in seen: continue
    seen.add(k); unique.append(e)

def swift(t):
    return '"' + t.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'
lines = []
for tab, kind, title, subtitle, section in unique:
    sec = swift(section) if section else 'nil'
    lines.append(f'        .init(tab: {swift(tab)}, title: {swift(title)}, subtitle: {swift(subtitle)}, section: {sec}),')
out = os.path.join(app, 'Views', 'Settings', 'SettingsSearchIndex.swift')
open(out, 'w').write('''import Foundation

/// Suchindex der Einstellungen (deutsche Schlüssel; Anzeige über `L(dynamic:)`).
/// Erzeugt mit tools/settings-search/generate_index.py – nicht von Hand ändern.
nonisolated enum SettingsSearchIndex {
    struct Entry: Hashable, Sendable {
        let tab: String
        let title: String
        let subtitle: String
        /// Aufklappbarer Abschnitt, in dem die Einstellung liegt (nil = immer sichtbar).
        let section: String?
    }

    static let entries: [Entry] = [
''' + '\n'.join(lines) + '''
    ]
}
''')
print(len(unique), 'Einträge')
