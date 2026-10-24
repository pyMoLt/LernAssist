import re, sys, json, glob, os
sys.path.insert(0, os.path.dirname(__file__))
from wrap import scan_literal
def key_of(lit):
    body = lit[3:-3] if lit.startswith('"""') else lit[1:-1]
    if lit.startswith('"""'):
        lines = body.split('\n')
        # Mehrzeilig: Einrückung der schließenden Zeile entfernen
        indent = len(lines[-1]) - len(lines[-1].lstrip())
        body = '\n'.join(l[indent:] for l in lines[1:-1])
        body = body.replace('\\\n', '')
    out=[]; j=0
    while j < len(body):
        c = body[j]
        if c == '\\' and j+1 < len(body):
            n = body[j+1]
            if n == '(':
                depth=1; k=j+2
                while k < len(body) and depth:
                    if body[k]=='"':
                        e=scan_literal(body,k); k = e if e else k+1; continue
                    if body[k]=='(': depth+=1
                    elif body[k]==')': depth-=1
                    k+=1
                out.append('%@'); j=k; continue
            if n == 'n': out.append('\n'); j+=2; continue
            if n == 't': out.append('\t'); j+=2; continue
            if n in '"\\\'': out.append(n); j+=2; continue
            if n == 'u':
                m = re.match(r'\\u\{([0-9A-Fa-f]+)\}', body[j:])
                if m: out.append(chr(int(m.group(1),16))); j+=len(m.group(0)); continue
        out.append(c); j+=1
    return ''.join(out)
if __name__ == '__main__':
    keys = {}
    root = sys.argv[1]
    for f in glob.glob(root+'/**/*.swift', recursive=True):
        s = open(f).read()
        for m in re.finditer(r'\bL\(\s*(?=")', s):
            e = scan_literal(s, m.end())
            if e: keys.setdefault(key_of(s[m.end():e]), f.replace(root+'/',''))
    # Dynamische Schlüssel
    s = open(root+'/ViewModels/ChatViewModel+SlashCommands.swift').read()
    for m in re.finditer(r'(description|paramHint):\s*(?=")', s):
        e = scan_literal(s, m.end()); keys.setdefault(key_of(s[m.end():e]), 'slash')
    for f in glob.glob(root+'/**/*.swift', recursive=True):
        s=open(f).read()
        for em in re.finditer(r'enum (LearningStyle|ReviewTab|FlashcardTab|PracticeScope|\w*Tab)\b[^{]*\{', s):
            body = s[em.end(): em.end()+3000]
            for c in re.finditer(r'case \w+ = (?=")', body):
                e = scan_literal(body, c.end())
                if e: keys.setdefault(key_of(body[c.end():e]), 'enum')
    json.dump(keys, open(sys.argv[2],'w'), ensure_ascii=False, indent=0)
    print(len(keys))
