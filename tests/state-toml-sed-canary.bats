#!/usr/bin/env bats
# #429: fixtures must NOT edit TOML state (config.toml / state/*.toml under
# $HOME/.claude/devagent) with `sed -i` — the #335 migration moved all such edits
# to the fail-loud `_toml.py` helpers (a bare `sed -i` silently no-ops on a regex
# miss, corrupting a fixture without failing). That migration (~78 copies) was
# verified by eye and NOTHING committed pinned it, so the idiom can silently
# return. This canary pins it.
#
# #335 recorded that the DOMINANT historical form (58 of ~84) was a CONTINUATION
# LINE sed — `sed -i 's/…/…/' \` with the TOML path on the next line — and that a
# VARIABLE-PATH sed (`sed -i … "$state_file"`, no literal `.toml` on the line) is
# the evasion a naive `.toml`-string grep misses. So this canary:
#   1. Joins backslash-continued lines FIRST (via _join_continuations), so the
#      dominant continuation form is scanned as one logical line — not a blind spot.
#   2. FLAGs a `sed … -i/--in-place` whose target is EITHER a literal `.toml` /
#      `.claude/devagent` path OR a `$var` named state/toml/config/active (the
#      state-file naming convention).
#
# Curated exclusions: exactly ONE file — this canary's own source, whose self-test
# @tests printf planted patterns (excluded by basename via find `! -name`, never a
# directory). No OTHER fixture seds state TOML (all real `sed -i` edit checklist.md /
# source / draft.md). Any future addition must be enumerated line-anchored WITH a
# rationale.
#
# Accepted residual evasions (documented, NOT covered — would need data-flow
# analysis, out of scope for a grep canary):
#   - A NEUTRAL var name that carries no keyword and whose `.toml` path is assigned
#     on a SEPARATE statement, e.g. `f="…/x.toml"; sed -i … "$f"` (production
#     state.sh itself uses `$f`). The named #335 regression used `"$state_file"`,
#     which the `state` arm DOES catch; this is the residual beyond it.
#   - Exotic flag orders like `sed -ri` (no space-delimited `-i` token). Current
#     style is `sed -i` / `sed -i -E` / `sed -E -i`, all covered.
#   - A state sed hidden behind a backslash-continued COMMENT line (`# note … \`
#     then the sed): _join_continuations merges them, and the comment-line filter
#     (leading `#`) then drops the joined line. Contrived, not in-tree style.

REPO="${BATS_TEST_DIRNAME}/.."

# Shared FLAG regex — used by the HEAD-clean test and every planted self-test so
# there is no drift. Matches `sed` + optional flag tokens + an in-place flag
# (-i / --in-place), then anywhere later a state target.
FLAG_RE='sed[[:space:]]+(-[A-Za-z]+[[:space:]]+)*(-i|--in-place).*(\.toml|\.claude/devagent|\$\{?[A-Za-z_]*([Ss]tate|[Tt]oml|[Cc]onfig|[Aa]ctive)[A-Za-z_]*)'

# Join backslash-continued lines within each file, reporting the STARTING line, so
# a continuation-line sed is scanned as one logical line (#335's dominant form).
_join_continuations() {
  local f
  for f in "$@"; do
    awk '
      {
        cur = $0
        if (prev != "") { cur = prev cur } else { startline = FNR }
        if (cur ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, " ", cur); prev = cur; next }
        printf "%s:%d: %s\n", FILENAME, startline, cur
        prev = ""
      }
      END { if (prev != "") printf "%s:%d: %s\n", FILENAME, startline, prev }
    ' "$f"
  done
}

# Scan the given files for a state-TOML sed, dropping comment lines.
_scan_state_sed() {
  _join_continuations "$@" | grep -E "$FLAG_RE" | grep -vE ':[0-9]+:[[:space:]]*#' || true
}

@test "no sed -i against TOML state in test fixtures (#429/#335)" {
  local files hits
  # Enumerate the fixture surface, excluding the canary's own file (its self-tests
  # carry planted patterns). find keeps continuation-aware _join_continuations fed.
  mapfile -t files < <(find "$REPO/tests" \( -name '*.bats' -o -name '*.bash' \) \
    ! -name 'state-toml-sed-canary.bats' | sort)
  [ "${#files[@]}" -gt 0 ] || { echo "no fixture files found — scan surface empty?" >&2; return 1; }

  hits="$(_scan_state_sed "${files[@]}")"
  [ -z "$hits" ] || {
    echo "sed -i on TOML state in a fixture — use a _toml.py helper (#335):" >&2
    echo "$hits" >&2
    return 1
  }
}

@test "canary catches a planted variable-path sed against state (#429 AC1)" {
  local tmp; tmp="$(mktemp -d)"
  printf 'sed -i "s/x = 1/x = 2/" "$state_file"\n' > "$tmp/planted.bats"
  run _scan_state_sed "$tmp/planted.bats"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  rm -rf "$tmp"
}

@test "canary catches a planted literal .toml sed against state (#429 AC2)" {
  local tmp; tmp="$(mktemp -d)"
  printf 'sed -i "s/a/b/" "$HOME/.claude/devagent/state/proj.toml"\n' > "$tmp/planted.bats"
  run _scan_state_sed "$tmp/planted.bats"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  rm -rf "$tmp"
}

@test "canary catches a planted CONTINUATION-line sed against state (#429/#335 dominant form)" {
  local tmp; tmp="$(mktemp -d)"
  # The #335 dominant shape: sed -i on one line, the state path on the next.
  printf 'sed -i '\''s/a/b/'\'' \\\n  "$HOME/.claude/devagent/state/proj.toml"\n' \
    > "$tmp/planted.bats"
  run _scan_state_sed "$tmp/planted.bats"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  rm -rf "$tmp"
}

@test "canary catches a flag-order variant sed -E -i against state (#429)" {
  local tmp; tmp="$(mktemp -d)"
  printf 'sed -E -i "s/a/b/" "$state_file"\n' > "$tmp/planted.bats"
  run _scan_state_sed "$tmp/planted.bats"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  rm -rf "$tmp"
}

@test "canary does not flag a legitimate checklist.md sed (#429 negative)" {
  local tmp; tmp="$(mktemp -d)"
  printf 'sed -i "s/^- \\[ \\]/- [x]/" "$DEVDOC/Issue-1/checklist.md"\n' > "$tmp/legit.bats"
  run _scan_state_sed "$tmp/legit.bats"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  rm -rf "$tmp"
}
