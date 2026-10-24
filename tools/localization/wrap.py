import re, sys, json, os
# Wraps UI string literals in L(...). Usage: wrap.py <root> <file>... ; prints stats, writes files in place.
TRIGGERS = [r'\bText\(', r'\bButton\(', r'\bLabel\(', r'\bTextField\(', r'\bSecureField\(', r'\bToggle\(', r'\bMenu\(',
            r'\bSection\(', r'\bPicker\(', r'\.help\(', r'\.settingHelp\(', r'\.accessibilityLabel\(', r'\.accessibilityHint\(',
            r'\.confirmationDialog\(', r'\.alert\(', r'\.navigationTitle\(', r'\bProgressView\(',
            r'\btitle:\s*', r'\bsubtitle:\s*', r'\bhelp:\s*', r'\blabel:\s*', r'\bmessage:\s*', r'\bplaceholder:\s*',
            r'\bsummary:\s*', r'\bhint:\s*', r'\bcaption:\s*', r'\bheadline:\s*',
            r'\bmessageText\s*=\s*', r'\binformativeText\s*=\s*', r'withTitle:\s*', r'NSMenu\(title:\s*', r'\bwindow\.title\s*=\s*',
            r'\.prompt\s*=\s*', r'\bpanel\.message\s*=\s*', r'\bstatus:\s*',
            r'\blabeledField\(', r'\bstepper\(', r'\bdomainField\(', r'\bwelcomePrompt\(', r'\bpracticeButton\(', r'\bstepperBadge\(',
            r'\bstepTitle\(', r'\bsummaryRow\([^,\n]*,\s*', r'\bstatusText\s*=\s*', r'\bstatus\s*=\s*', r'\bloadError\s*=\s*', r'\bmodelLoadError\s*=\s*',
            r'\brerankStatus\s*=\s*', r'\bfeatureDescription:\s*', r'\bemptyOptionLabel:\s*', r'\baccessibilityLabel:\s*', r'\bstringValue\s*=\s*',
            r'\bpanel\.title\s*=\s*', r'\bparts\.append\(', r'\bvar parts = \[', r'\blet message = ', r'\bChoiceChip\(title:\s*',
            r'\breturn\s+(?="[^"\n]*[ äöüÄÖÜß])']
TRIG = re.compile('|'.join('(?:%s)' % t for t in TRIGGERS))
PROP = re.compile(r'\bvar\s+(title|subtitle|label|help|displayName|navigationSubtitle|shortTitle|shortLabel|summary|helpText|caption|hint|statusText|placeholder|explanation)\w*\s*:\s*String\s*\{')

def scan_literal(s, i):
    """s[i] == '"'. Returns end index (exclusive) of the literal or None."""
    if s.startswith('"""', i):
        j = s.find('"""', i + 3)
        while j != -1 and s[j-1] == '\\':
            j = s.find('"""', j + 1)
        return None if j == -1 else j + 3
    j = i + 1
    while j < len(s):
        c = s[j]
        if c == '\\':
            if j + 1 < len(s) and s[j+1] == '(':
                depth = 1; k = j + 2
                while k < len(s) and depth:
                    if s[k] == '"':
                        e = scan_literal(s, k)
                        if e is None: return None
                        k = e; continue
                    if s[k] == '(': depth += 1
                    elif s[k] == ')': depth -= 1
                    k += 1
                j = k; continue
            j += 2; continue
        if c == '"': return j + 1
        if c == '\n': return None
        j += 1
    return None

def outside_interp(lit):
    out = []; j = 0
    while j < len(lit):
        if lit[j] == '\\' and j + 1 < len(lit) and lit[j+1] == '(':
            depth = 1; k = j + 2
            while k < len(lit) and depth:
                if lit[k] == '(': depth += 1
                elif lit[k] == ')': depth -= 1
                k += 1
            j = k; continue
        out.append(lit[j]); j += 1
    return ''.join(out)

def wants(lit):
    body = lit[3:-3] if lit.startswith('"""') else lit[1:-1]
    text = outside_interp(body)
    if not re.search(r'[A-Za-zÄÖÜäöüß]{2}', text): return False
    if re.fullmatch(r'[a-z0-9_.\-]+', text): return False   # SF-Symbol/Bezeichner
    return True

def wrap_file(path):
    s = open(path).read()
    out = []; i = 0; n = 0
    positions = []
    for m in ([] if os.environ.get('PROPONLY') else TRIG.finditer(s)):
        k = m.end()
        while k < len(s) and s[k] in ' \t': k += 1
        if k < len(s) and s[k] == '"': positions.append(k)
    # Properties with display text
    for m in PROP.finditer(s):
        depth = 1; k = m.end()
        while k < len(s) and depth:
            c = s[k]
            if c == '"':
                e = scan_literal(s, k)
                if e is None: break
                prev = s[max(0,k-12):k]
                if re.search(r'(:\s*|return\s+|\?\s*|:\s*\n\s*)$', prev) or re.search(r'(case [^\n]*:\s*)$', s[max(0,k-80):k]):
                    positions.append(k)
                k = e; continue
            if c == '{': depth += 1
            elif c == '}': depth -= 1
            k += 1
    # Ternär-Zweige in Zeilen mit Auslöser
    for line_m in ([] if os.environ.get('PROPONLY') else re.finditer(r'[^\n]*', s)):
        line = line_m.group(0)
        if not TRIG.search(line): continue
        for t in re.finditer(r'(\?\?|\?|:)\s*(?=")', line):
            positions.append(line_m.start() + t.end())
    positions = sorted(set(positions))
    last = 0
    for p in positions:
        if p < last: continue
        e = scan_literal(s, p)
        if e is None: continue
        lit = s[p:e]
        before = s[max(0, p-10):p]
        if before.endswith('L(') or before.rstrip().endswith('verbatim:') or not wants(lit):
            continue
        out.append(s[last:p]); out.append('L(' + lit + ')'); last = e; n += 1
    out.append(s[last:])
    new = ''.join(out)
    if new != s: open(path, 'w').write(new)
    return n

if __name__ == '__main__':
  total = 0
  for f in sys.argv[1:]:
    c = wrap_file(f); total += c
    if c: print(c, f)
  print('TOTAL', total)
