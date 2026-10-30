#!/usr/bin/env bash
# scripts/migrate-checklist-numbering.sh — #558, #885. Renumber an IN-FLIGHT
# checklist to the current numbering (numbers are positions in execution order).
#
#   migrate-checklist-numbering.sh [--dry-run] [--reverse | --reverse-558] <issue-dir>...
#   migrate-checklist-numbering.sh [--dry-run] [--reverse | --reverse-558] --all
#
# Three schemes, keyed by step NAME:
#   pre-#558  numbers were permanent IDs (ship was row 15).
#   #558      positions: mergetoall 19, then updatewbs through cleanup at 20-23.
#   #885      the current scheme: mergemr 20 follows mergetoall, so updatewbs,
#             impact, lessonslearned and cleanup are 21-24.
#
# No flag: migrate to the current scheme (#885) from either older one. A
# checklist that is not complete also gains `- [ ] 20. mergemr` in its ACTIVE
# block (the last `## Revision N` block, else the whole file), after mergetoall,
# else after ship; the glyph is `-` when that block's ship row is `[-]`. Nothing
# is inserted when the block has no ship row or already has a mergemr row.
# Older revision blocks are renumbered but gain no row.
# --reverse      undoes #885 (back to the #558 scheme), dropping every mergemr
#                row in every block. Required for a clean `git revert` of #885.
# --reverse-558  undoes #558 (back to the pre-#558 scheme), dropping mergemr rows
#                the same way. Required for a clean `git revert` of #558.
# The two reverse flags are mutually exclusive. A revert restores the older
# code, so in-flight checklists must go back with it.
#
# Keyed by step NAME, never by old number: each row's name determines its new
# number. That makes the transform correct on an old-scheme file, a no-op on a
# current one, and safe on a file that mixes both (a revision block appended
# after the renumber) — none of which a number→number map could manage.
#
# COMPLETED checklists are skipped by default, in every direction: the #558
# operator waiver keeps finished records at the numbers they were worked under.
# --include-completed overrides that for the rare case where an old record must
# be re-driven.
set -euo pipefail
DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=lib/paths.sh
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
# shellcheck source=lib/io.sh
. "$DEVAGENT_ROOT/scripts/lib/io.sh"

DRY=0; ALL=0; INCLUDE_DONE=0; REVERSE=0; REVERSE558=0
declare -a DIRS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)           DRY=1 ;;
    --all)               ALL=1 ;;
    --include-completed) INCLUDE_DONE=1 ;;
    --reverse)           REVERSE=1 ;;
    --reverse-558)       REVERSE558=1 ;;
    -h|--help)
      sed -n '2,/^[^#]/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown flag: $1" ;;
    *)  DIRS+=("$1") ;;
  esac
  shift
done
[ "$REVERSE" -eq 1 ] && [ "$REVERSE558" -eq 1 ] \
  && die "--reverse and --reverse-558 are mutually exclusive"

if [ "$ALL" -eq 1 ]; then
  [ "${#DIRS[@]}" -eq 0 ] || die "--all takes no issue-dir arguments"
  cfg="$(config_path)"
  [ -f "$cfg" ] || die "no config at $cfg"
  while IFS= read -r devdoc; do
    [ -d "$devdoc" ] || continue
    while IFS= read -r d; do DIRS+=("$d"); done \
      < <(find "$devdoc" -mindepth 2 -maxdepth 2 -name checklist.md -printf '%h\n' | sort)
  done < <(python3 - "$cfg" <<'PY'
import sys, tomllib
d = tomllib.load(open(sys.argv[1], 'rb'))
for name, p in (d.get('project') or {}).items():
    dd = p.get('devdoc_dir')
    if dd: print(dd)
PY
)
fi
[ "${#DIRS[@]}" -gt 0 ] || die "usage: migrate-checklist-numbering.sh [--dry-run] [--reverse | --reverse-558] <issue-dir>... | --all"

migrated=0; skipped_done=0; already=0
for d in "${DIRS[@]}"; do
  f="${d%/}/checklist.md"
  [ -f "$f" ] || { warn "no checklist at $f — skipping"; continue; }
  out="$(DRY="$DRY" INCLUDE_DONE="$INCLUDE_DONE" REVERSE="$REVERSE" REVERSE558="$REVERSE558" python3 - "$f" <<'PY'
import os, re, sys
NEW = {'pull':0,'research':1,'draft':2,'spike':3,'scope':4,'improve':5,'prune':6,
       'tighten':7,'branch':8,'implement':9,'quality':10,'document':11,'commit':12,
       'analyze':13,'draftmr':14,'review':15,'redmr':16,'preship':17,'ship':18,
       'mergetoall':19,'mergemr':20,'updatewbs':21,'impact':22,'lessonslearned':23,
       'cleanup':24}
# MID (#558 to #885) is NEW without mergemr, every row after it one lower.
MID = {k: v - (v > NEW['mergemr']) for k, v in NEW.items() if k != 'mergemr'}
OLD = {'pull':0,'research':22,'draft':1,'spike':23,'scope':2,'improve':3,'prune':4,
       'tighten':5,'branch':6,'implement':7,'quality':8,'document':9,'commit':10,
       'analyze':11,'draftmr':12,'review':13,'redmr':14,'preship':21,'ship':15,
       'mergetoall':16,'updatewbs':17,'impact':18,'lessonslearned':19,'cleanup':20}
reverse = os.environ.get("REVERSE") == "1"
reverse558 = os.environ.get("REVERSE558") == "1"
TARGET = MID if reverse else OLD if reverse558 else NEW
# Capture the original whitespace run so column alignment is preserved exactly.
ROW = re.compile(r'^(- \[(.)\])(\s+)(\d+)(\.\s+)([A-Za-z][A-Za-z0-9_-]*)(.*)$')
path = sys.argv[1]
src = open(path, encoding='utf-8').read()
lines = src.splitlines(keepends=True)
def scan():
    return [(i, m) for i, m in ((i, ROW.match(l.rstrip('\n'))) for i, l in enumerate(lines)) if m]
rows = scan()
if not rows:
    print("NOROWS"); sys.exit(0)
complete = all(m.group(2) in ('x', '-') for _, m in rows)
dropped = 0
if reverse or reverse558:
    # Neither older scheme has a mergemr step: drop the row in EVERY block
    # before the unknown-name check, which would otherwise refuse it.
    keep = [l for l in lines if not ((m := ROW.match(l.rstrip('\n'))) and m.group(6) == 'mergemr')]
    dropped = len(lines) - len(keep)
    lines = keep
    rows = scan()
unknown = sorted({m.group(6) for _, m in rows} - set(TARGET))
if unknown:
    print("UNKNOWN " + ",".join(unknown)); sys.exit(0)
if os.environ.get("INCLUDE_DONE") != "1" and complete:
    print("DONE"); sys.exit(0)
changed = 0
for i, m in rows:
    new = str(TARGET[m.group(6)])
    if new == m.group(4):
        continue
    # Keep the field width constant when the new number fits; widen by one
    # space otherwise — rjust cannot widen, and a fused '- [ ]10.' row exits
    # the ROW grammar, invisible to every checklist reader (r2 MAJOR-1).
    pad = max(len(m.group(3)) + len(m.group(4)) - len(new), 1)
    lines[i] = f"{m.group(1)}{' ' * pad}{new}{m.group(5)}{m.group(6)}{m.group(7)}\n"
    changed += 1
inserted = 0
if not (reverse or reverse558) and not complete:
    # #885: only the ACTIVE block (the last `## Revision N` block, up to the next
    # `## ` heading; else the whole file) gains the mergemr row.
    heads = [i for i, l in enumerate(lines) if l.startswith('## Revision ')]
    lo = heads[-1] + 1 if heads else 0
    hi = next((i for i in range(lo, len(lines)) if lines[i].startswith('## ')), len(lines))
    block = {}
    for i in range(lo, hi):
        m = ROW.match(lines[i].rstrip('\n'))
        if m:
            block.setdefault(m.group(6), (i, m.group(2)))
    if 'ship' in block and 'mergemr' not in block:
        at = block.get('mergetoall', block['ship'])[0]
        g = '-' if block['ship'][1] == '-' else ' '
        if not lines[at].endswith('\n'):
            lines[at] += '\n'
        lines.insert(at + 1, f"- [{g}] {NEW['mergemr']}. mergemr\n")
        inserted = 1
if changed == 0 and not inserted and not dropped:
    print("ALREADY"); sys.exit(0)
if os.environ.get("DRY") != "1":
    # Same-dir mkstemp (not a fixed ".tmp"): concurrent runs cannot collide, and
    # a crash cannot strand a predictable file that cleanup.sh would then commit.
    import tempfile
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or '.', prefix='.checklist-', suffix='.tmp')
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as fh:
            fh.write(''.join(lines))
        os.chmod(tmp, os.stat(path).st_mode & 0o7777)
        os.replace(tmp, path)                      # same-dir rename = atomic
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise
print(f"MIGRATED {changed} rows" + (", +mergemr" if inserted else ", -mergemr" if dropped else ""))
PY
)"
  case "$out" in
    DONE)      skipped_done=$((skipped_done + 1)) ;;
    ALREADY)   already=$((already + 1)) ;;
    NOROWS)    warn "$f: no checklist rows — skipping" ;;
    UNKNOWN*)  die "$f: unrecognised step name(s): ${out#UNKNOWN }. Refusing to guess." ;;
    MIGRATED*) migrated=$((migrated + 1))
               printf '%s %s (%s)\n' "$([ "$DRY" -eq 1 ] && echo 'would migrate' || echo 'migrated')" \
                      "$f" "${out#MIGRATED }" ;;
    *)         die "$f: unexpected migrator output: $out" ;;
  esac
done

printf '\n%s: %d migrated, %d already current, %d completed (skipped)\n' \
  "$([ "$DRY" -eq 1 ] && echo 'dry-run' || echo 'migrate')" \
  "$migrated" "$already" "$skipped_done"
