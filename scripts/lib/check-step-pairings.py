#!/usr/bin/env python3
"""check-step-pairings.py — #558. Verify that every ADJACENT step-name/number
pairing on a live surface agrees with the canonical numbering.

    check-step-pairings.py [--root DIR] [--list-bare]

Exit 0 when every pairing agrees; 1 when any disagrees (offenders on stdout).

WHAT IS CHECKED (decidable): forms where a step NAME sits directly beside a
number. The pattern set is a CORPUS of every spelling ever observed on a live
surface — `step 9 (implement)`, `implement (9)`, `implement(9)`, `9 implement`,
`9. implement`, `commit step (12)`, `ship.sh (18)`, `` `cleanup` (23) ``,
`improve 5, review 15` (list), `17 = preship`, `20 for updatewbs`,
`23/cleanup`, `18 (ship)`, and ONE cross-line form — `<key> = N` directly
above `<key>_name = "<step>"` (r3 MAJOR-1, the state.toml shape). Each family
has a wrong-numbered fixture line in tests/checklist-numbering.bats; when a
NEW spelling ships stale, add it there first (the test fails until PAIRED
learns it). r2 BLOCKING-3 was five of these families being invisible to both
outputs at once.

SCOPE LIMIT (state it, don't discover it): except for the key/key_name window
above, every pattern is LINE-scoped. A pairing spread across lines in any
other layout — a table row split by wrapping, a list where names and numbers
alternate lines — is invisible to this checker AND absent from --list-bare
when no `step N` token survives on either line. That is a known shape of
blind spot, not a proof of absence.

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
    # Tolerates the repo's dominant spelling, e.g. Step 13 (`/devagent:analyze`)
    (re.compile(r'[Ss]teps? (\d+) \(`?(?:/devagent:)?(%s)`?\)' % _N), 2, 1),
    (re.compile(r'\b(%s) \((\d+)\)' % _N), 1, 2),
    (re.compile(r'\b(%s)\((\d+)\)' % _N), 1, 2),
    (re.compile(r'(?<![\w.#/-])(\d+)\.? (%s)\b' % _N), 2, 1),
    # r2 BLOCKING-3: the families below shipped stale while invisible to both
    # outputs. One fixture line each in the corpus test; keep them in step.
    (re.compile(r'\b(%s) step \((\d+)\)' % _N), 1, 2),       # commit step (12)
    (re.compile(r'\b(%s)\.sh \((\d+)\)' % _N), 1, 2),        # ship.sh (18)
    (re.compile(r'`(%s)` \((\d+)\)' % _N), 1, 2),            # `cleanup` (23)
    (re.compile(r'\b(%s) (\d+)(?=[,;.)\]]|$)' % _N), 1, 2),  # improve 5, review 15
    (re.compile(r'\b(\d+) = (%s)\b' % _N), 2, 1),            # 17 = preship
    (re.compile(r'\b(\d+) for `?(%s)`?\b' % _N), 2, 1),      # 20 for `updatewbs`
    (re.compile(r'\b(\d+)/(%s)\b' % _N), 2, 1),              # 23/cleanup
    (re.compile(r'(?<![\w.#/-])(\d+) \(`?(%s)`?\)' % _N), 2, 1),  # 18 (ship)
]
# r3 MAJOR-1: the one observed CROSS-LINE family — `<key> = N` directly above
# `<key>_name = "<step>"` (the state.toml shape). This is the sole exception to
# the line-scoped corpus; any other multi-line spelling is out of scope and the
# docstring says so.
KEYNUM = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(\d+)\s*(#.*)?$')
KEYNAME = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)_name\s*=\s*"(%s)"' % _N)
BARE = re.compile(r'[Ss]teps? (\d+)\b')
# Issue/PR refs and exit codes collide textually with step numbers.
NOISE = re.compile(r'#\d{2,}|Issue-\d|\brc \d|exit code')
# Opt-out for lines that deliberately cite PRE-#558 numbers — e.g. comments
# explaining the wrong-row hazard, or this file's own worked example. Must be
# explicit and greppable so an exemption is never silent.
EXEMPT = re.compile(r'#558-old-scheme')


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
        prev_keynum = None   # (key, num, exempt) from the previous line
        for i, line in enumerate(text.splitlines(), 1):
            # NOISE spans (issue refs, rc codes) collide textually with step
            # numbers. Skip only the OVERLAPPING match — never the whole line:
            # dropping the line hid 18 of 171 bare sites and 12 pairings from
            # BOTH outputs, including the stale config.toml.skel:101 that
            # reached ship (#558 redmr MAJOR-1a). EXEMPT is likewise scoped to
            # the PAIRING CHECK only (r2 MAJOR-2): an exempt line's pairings
            # are neither checked nor recorded as decided, so its `step N`
            # forms still reach the --list-bare triage list below.
            exempt = bool(EXEMPT.search(line))
            # Cross-line window: `<key> = N` on the line above pairs with
            # `<key>_name = "<step>"` here.
            mkn = KEYNAME.match(line)
            if mkn and prev_keynum and prev_keynum[0] == mkn.group(1):
                if not (exempt or prev_keynum[2]):
                    checked += 1
                    name, num = mkn.group(2), prev_keynum[1]
                    if NEW[name] != num:
                        bad.append(f"{rel}:{i}: '{prev_keynum[0]} = {num}' + "
                                   f"'{mkn.group(0).strip()}' — {name} is {NEW[name]}")
            mnum = KEYNUM.match(line)
            prev_keynum = (mnum.group(1), int(mnum.group(2)), exempt) if mnum else None
            noise_spans = [m.span() for m in NOISE.finditer(line)]
            def _noisy(span):
                return any(ns <= span[0] < ne for ns, ne in noise_spans)
            paired_spans = []
            for pat, gname, gnum in PAIRED:
                for m in pat.finditer(line):
                    if exempt:
                        continue
                    paired_spans.append(m.span())
                    if _noisy(m.span()):
                        continue
                    checked += 1
                    name, num = m.group(gname), int(m.group(gnum))
                    if NEW[name] != num:
                        bad.append(f"{rel}:{i}: '{m.group(0)}' — {name} is {NEW[name]}")
            if args.list_bare:
                for m in BARE.finditer(line):
                    # A bare site inside a paired match is already decided.
                    # NOISE does NOT suppress it: a triage list has no reason
                    # to filter, and filtering is what hid the ship defect.
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
