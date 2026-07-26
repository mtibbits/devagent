#!/usr/bin/env python3
"""check-step-pairings.py — #558. Verify that every ADJACENT step-name/number
pairing on a live surface agrees with the canonical numbering.

    check-step-pairings.py [--root DIR] [--list-bare]

Exit 0 when every pairing agrees; 1 when any disagrees (offenders on stdout).

WHAT IS CHECKED (decidable): forms where a step NAME sits directly beside a
number — `step 9 (implement)`, `implement (9)`, `implement(9)`, `9 implement`,
`9. implement`. Those cannot be ambiguous, so they are machine-checkable.

WHAT IS NOT CHECKED (undecidable): bare `step N` with no adjacent name. Prose
legitimately says "per-task commits begin in step 9" on a line that also
mentions `commit`, so no rule over a single line can decide it. That form
shipped stale twice on #558 (once past an eight-form census, once past its
nine-form correction), so `--list-bare` emits it as a REVIEW list for human
triage instead of pretending to decide it. Treat a non-empty --list-bare as
"read these", not "these are wrong".
"""
import argparse
import os
import re
import sys

NEW = {'pull': 0, 'research': 1, 'draft': 2, 'spike': 3, 'scope': 4, 'improve': 5,
       'prune': 6, 'tighten': 7, 'branch': 8, 'implement': 9, 'quality': 10,
       'document': 11, 'commit': 12, 'analyze': 13, 'draftmr': 14, 'review': 15,
       'redmr': 16, 'preship': 17, 'ship': 18, 'mergetoall': 19, 'updatewbs': 20,
       'impact': 21, 'lessonslearned': 22, 'cleanup': 23}

# Live surfaces only. Excluded by design: docs/plans (dated historical plans),
# CHANGELOG (historical entries + the #558 upgrade note, which must quote the
# old numbers to be useful), and **/fixtures (deliberately old-scheme corpora).
SCAN = ['commands', 'skills', 'agents', 'scripts', 'templates', 'docs-site',
        'hooks', '.claude-plugin', 'docs/specs', 'README.md']
SKIP_DIRS = ('__pycache__', os.sep + 'plans', os.sep + 'fixtures')

_N = '|'.join(NEW)
# (pattern, name-group, number-group)
PAIRED = [
    (re.compile(r'[Ss]teps? (\d+) \((%s)\)' % _N), 2, 1),
    (re.compile(r'\b(%s) \((\d+)\)' % _N), 1, 2),
    (re.compile(r'\b(%s)\((\d+)\)' % _N), 1, 2),
    (re.compile(r'(?<![\w.#/-])(\d+)\.? (%s)\b' % _N), 2, 1),
]
BARE = re.compile(r'[Ss]teps? (\d+)\b')
# Issue/PR refs and exit codes collide textually with step numbers.
NOISE = re.compile(r'#\d{2,}|Issue-\d|\brc \d|exit code')


def iter_files(root):
    for top in SCAN:
        target = os.path.join(root, top)
        if os.path.isfile(target):
            yield target
            continue
        for dirpath, _, filenames in os.walk(target):
            if any(k in dirpath for k in SKIP_DIRS):
                continue
            for fn in filenames:
                yield os.path.join(dirpath, fn)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', default=os.path.dirname(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    ap.add_argument('--list-bare', action='store_true',
                    help='also list undecidable bare `step N` sites for human triage')
    args = ap.parse_args()

    bad, bare, checked = [], [], 0
    for path in iter_files(args.root):
        try:
            with open(path, errors='replace') as fh:
                text = fh.read()
        except OSError:
            continue
        rel = os.path.relpath(path, args.root)
        for i, line in enumerate(text.splitlines(), 1):
            if NOISE.search(line):
                continue
            paired_spans = []
            for pat, gname, gnum in PAIRED:
                for m in pat.finditer(line):
                    checked += 1
                    paired_spans.append(m.span())
                    name, num = m.group(gname), int(m.group(gnum))
                    if NEW[name] != num:
                        bad.append(f"{rel}:{i}: '{m.group(0)}' — {name} is {NEW[name]}")
            if args.list_bare:
                for m in BARE.finditer(line):
                    if not any(s <= m.start() < e for s, e in paired_spans):
                        bare.append(f"{rel}:{i}: {line.strip()[:100]}")

    print(f"checked {checked} adjacent pairings across live surfaces")
    for b in sorted(set(bad)):
        print(b)
    if args.list_bare:
        print(f"\n-- {len(set(bare))} bare `step N` sites (UNDECIDABLE — human triage) --")
        for b in sorted(set(bare)):
            print(b)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
