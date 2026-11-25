# tests/lib/hold-fixture.bash — #962: the `_toy` fixture and readers shared by
# tests/hold.bats and tests/next-hold.bats. Load after lib/bats-helpers.
# shellcheck shell=bash
. "$(dirname "${BASH_SOURCE[0]}")/hermetic-env.bash"   # idempotent (#322, #338)

# _tset <key> <toml-value> / _tunset <key>: edit toy's state through the
# fail-loud TOML helper (#335), never sed.
_tset() { python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" set "$DA_HOME/state/toy.toml" "$1" "$2"; }
_tunset() { python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" unset "$DA_HOME/state/toy.toml" "$1"; }

# _toy: project `toy`, active Issue-7 (rows 0 pull, 2 draft, 4 scope done; 5
# improve in progress; 6 prune and 12 commit pending; a Log), and Issue-8.
_toy() {
  DEVDOC="$BATS_TEST_TMPDIR/devdoc"
  SRC="$BATS_TEST_TMPDIR/src"
  D="$DEVDOC/Issue-7"
  CK="$D/checklist.md"
  mkdir -p "$D" "$DEVDOC/Issue-8" "$SRC"
  cat > "$DA_HOME/config.toml" <<EOF
[project.toy]
source_dir = "$SRC"
devdoc_dir = "$DEVDOC"
EOF
  cat > "$DA_HOME/state/toy.toml" <<EOF
active_issue = "Issue-7"
issue_dir = "$D"
EOF
  cat > "$CK" <<'EOF'
- [x]  0. pull
- [x]  2. draft
- [x]  4. scope
- [~]  5. improve
- [ ]  6. prune
- [ ] 12. commit
- [ ] 24. cleanup

## Log
EOF
  printf '%s\n' '- [~]  5. improve' '' '## Log' > "$DEVDOC/Issue-8/checklist.md"
}

# _q <file>: a valid question file (options a recommended, b).
_q() {
  cat > "$1" <<'Q'
## Question

Proceed with round 4?

## Impediment

improve found 14 bugs after round 3 of 3.

## Options

- `a` (recommended) Run round 4.
- `b` Stop and prune.

## Evidence

analysis/2026-11-20-improve.md
Q
}

# _snap: every path under the devdoc and the state dir, then each file's
# checksum — the "nothing was written" witness.
_snap() {
  find "$DEVDOC" "$DA_HOME/state" | sort
  find "$DEVDOC" "$DA_HOME/state" -type f -exec sha256sum {} + | sort
}

# _rows <checklist>: the step rows, verbatim.
_rows() { grep -E '^- \[.\] +[0-9]+\.' "$1"; }

# _lib: source the libraries a test reads the format through.
_lib() {
  local l
  for l in paths io config checklist question-actions; do
    # shellcheck source=/dev/null
    source "$PLUGIN_ROOT/scripts/lib/$l.sh"
  done
}

# _question_stuck <step> <N> [kind]: a rendered question STUCK for <step>.
_question_stuck() {
  _lib
  _q "$BATS_TEST_TMPDIR/q.md"
  question_render "$BATS_TEST_TMPDIR/q.md" toy Issue-7 "$1" "$2" "r" "4 scope" 01 2026-11-20T10:31:00-05:00 > "$D/STUCK"
  [ -z "${3:-}" ] || sed -i "1s/.*/Kind:        $3/" "$D/STUCK"
}

# _tree: a copy of scripts/ and templates/ for a test that needs the probe tag,
# a stub park.sh or a fixture step. Sets TREE.
_tree() {
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE"
  cp -r "$PLUGIN_ROOT/scripts" "$PLUGIN_ROOT/templates" "$TREE/"
}

NF() { printf '%s\n' "$DA_HOME/state/notifications.jsonl"; }
_lines() { if [ -f "$(NF)" ]; then wc -l < "$(NF)" | tr -d ' '; else echo 0; fi; }
_field() { python3 "$PLUGIN_ROOT/tests/helpers/notify_probe.py" field "$(NF)" -1 "$1"; }
_native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m -- "$1"; else printf '%s\n' "$1"; fi; }
question_number_of() { ( _lib; question_number "$1" ); }
_parks() { grep -cE '^- [0-9-]+ [0-9:]+  park: issue parked' "$CK" || true; }
