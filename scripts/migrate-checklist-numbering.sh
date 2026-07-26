#!/usr/bin/env bash
# scripts/migrate-checklist-numbering.sh — #558. Renumber an IN-FLIGHT checklist
# from the pre-#558 scheme (numbers were permanent IDs) to the current one
# (numbers are positions in execution order).
#
#   migrate-checklist-numbering.sh [--dry-run] <issue-dir>...
#   migrate-checklist-numbering.sh [--dry-run] --all           # every in-flight
#                                                              # checklist in every
#                                                              # configured devdoc
#
# Keyed by step NAME, never by old number: each row's name determines its new
# number. That makes the transform correct on an old-scheme file, a no-op on a
# current one, and safe on a file that mixes both (a revision block appended
# after the renumber) — none of which a number→number map could manage.
#
# COMPLETED checklists are skipped by default: the #558 operator waiver keeps
# finished records at the numbers they were worked under. --include-completed
# overrides that for the rare case where an old record must be re-driven.
set -euo pipefail
DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=lib/paths.sh
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
# shellcheck source=lib/io.sh
. "$DEVAGENT_ROOT/scripts/lib/io.sh"

DRY=0; ALL=0; INCLUDE_DONE=0
declare -a DIRS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)           DRY=1 ;;
    --all)               ALL=1 ;;
    --include-completed) INCLUDE_DONE=1 ;;
    -h|--help)
      sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown flag: $1" ;;
    *)  DIRS+=("$1") ;;
  esac
  shift
done

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
[ "${#DIRS[@]}" -gt 0 ] || die "usage: migrate-checklist-numbering.sh [--dry-run] <issue-dir>... | --all"

migrated=0; skipped_done=0; already=0
for d in "${DIRS[@]}"; do
  f="${d%/}/checklist.md"
  [ -f "$f" ] || { warn "no checklist at $f — skipping"; continue; }
  out="$(DRY="$DRY" INCLUDE_DONE="$INCLUDE_DONE" python3 - "$f" <<'PY'
import os, re, sys
NEW = {'pull':0,'research':1,'draft':2,'spike':3,'scope':4,'improve':5,'prune':6,
       'tighten':7,'branch':8,'implement':9,'quality':10,'document':11,'commit':12,
       'analyze':13,'draftmr':14,'review':15,'redmr':16,'preship':17,'ship':18,
       'mergetoall':19,'updatewbs':20,'impact':21,'lessonslearned':22,'cleanup':23}
# Capture the original whitespace run so column alignment is preserved exactly.
ROW = re.compile(r'^(- \[(.)\])(\s+)(\d+)(\.\s+)([A-Za-z][A-Za-z0-9_-]*)(.*)$')
path = sys.argv[1]
src = open(path, encoding='utf-8').read()
lines = src.splitlines(keepends=True)
rows = [(i, m) for i, m in ((i, ROW.match(l.rstrip('\n'))) for i, l in enumerate(lines)) if m]
if not rows:
    print("NOROWS"); sys.exit(0)
unknown = sorted({m.group(6) for _, m in rows} - set(NEW))
if unknown:
    print("UNKNOWN " + ",".join(unknown)); sys.exit(0)
if os.environ.get("INCLUDE_DONE") != "1":
    if all(m.group(2) in ('x', '-') for _, m in rows):
        print("DONE"); sys.exit(0)
changed = 0
for i, m in rows:
    new = str(NEW[m.group(6)])
    if new == m.group(4):
        continue
    width = len(m.group(3)) + len(m.group(4))     # keep the field width constant
    lines[i] = f"{m.group(1)}{new.rjust(width)}{m.group(5)}{m.group(6)}{m.group(7)}\n"
    changed += 1
if changed == 0:
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
print(f"MIGRATED {changed}")
PY
)"
  case "$out" in
    DONE)      skipped_done=$((skipped_done + 1)) ;;
    ALREADY)   already=$((already + 1)) ;;
    NOROWS)    warn "$f: no checklist rows — skipping" ;;
    UNKNOWN*)  die "$f: unrecognised step name(s): ${out#UNKNOWN }. Refusing to guess." ;;
    MIGRATED*) migrated=$((migrated + 1))
               printf '%s %s (%s rows)\n' "$([ "$DRY" -eq 1 ] && echo 'would migrate' || echo 'migrated')" \
                      "$f" "${out#MIGRATED }" ;;
    *)         die "$f: unexpected migrator output: $out" ;;
  esac
done

printf '\n%s: %d migrated, %d already current, %d completed (skipped)\n' \
  "$([ "$DRY" -eq 1 ] && echo 'dry-run' || echo 'migrate')" \
  "$migrated" "$already" "$skipped_done"
