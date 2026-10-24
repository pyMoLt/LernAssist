"""Erzeugt Lernassist/Localization/EnglishStrings.swift aus translations-en.json und meldet
Oberflächentexte im Code, für die noch eine Übersetzung fehlt.

    python3 tools/localization/generate.py
"""
import json, os, subprocess, sys
here = os.path.dirname(os.path.abspath(__file__))
app = os.path.join(here, '..', '..', 'Lernassist')
table = json.load(open(os.path.join(here, 'translations-en.json')))
tmp = os.path.join(here, '.keys.json')
subprocess.run([sys.executable, '-I', os.path.join(here, 'extract.py'), app, tmp], check=True, capture_output=True)
missing = [k for k in json.load(open(tmp)) if k not in table]
os.remove(tmp)
def swift(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\t', '\\t') + '"'
lines = [f'        {swift(k)}: {swift(v)},' for k, v in sorted(table.items()) if k != v]
open(os.path.join(app, 'Localization', 'EnglishStrings.swift'), 'w').write(
    'import Foundation\n\n/// Englische Fassungen der Oberflächentexte. Schlüssel: der deutsche Text im Code (mit `%@` für\n'
    '/// Platzhalter). Erzeugt mit tools/localization/generate.py aus translations-en.json – nicht von Hand ändern.\n'
    'nonisolated enum EnglishStrings {\n    static let table: [String: String] = [\n' + '\n'.join(lines) + '\n    ]\n}\n')
print(f'{len(lines)} Einträge geschrieben, {len(missing)} ohne Übersetzung')
for m in missing: print('  fehlt:', json.dumps(m, ensure_ascii=False))
