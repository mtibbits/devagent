#!/usr/bin/env bats
# #338: every setup layer a .bats `load`s MUST source the shared hermetic-env
# guard (#322), so hermeticity has exactly one home and a NEW layer can't skip
# it. Bare-setup file (sources the guard directly, not via a loaded layer).
# Scope note (#338 improve A1): this canary covers `load`-ed layers only. Other
# sourcing mechanisms (e.g. HARNESS=…/skill-fixture-check.sh) are out of its
# reach and out of this issue's scope.
REPO="${BATS_TEST_DIRNAME}/.."
. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"


# Extract every `load <name>` directive from the given files, stripping an
# optional wrapping quote. #428: the name may be BARE, single-quoted, OR
# double-quoted — a `load "layer"` used to escape this canary (the same
# blindness class as the #338 comment-line fix). The char class `["']?` on both
# ends admits all three forms. Shared by _loaded_layers and the fixture test so
# both exercise the identical regex.
_extract_load_names() {
  grep -rhoE "^[[:space:]]*load[[:space:]]+[\"']?[A-Za-z0-9_./-]+[\"']?" "$@" \
    | sed -E "s/^[[:space:]]*load[[:space:]]+[\"']?//; s/[\"']?[[:space:]]*\$//"
}

# Resolve every `load X` in tests/*.bats to its helper file (bats adds .bash).
_loaded_layers() {
  _extract_load_names "$REPO"/tests/*.bats \
    | while read -r name; do
        for cand in "$REPO/tests/$name" "$REPO/tests/$name.bash"; do
          [ -f "$cand" ] && { echo "$cand"; break; }
        done
      done | sort -u
}

@test "every loaded test setup layer sources the hermetic-env guard (#338)" {
  local missing=() layer
  while read -r layer; do
    # Match an actual source directive at line start, not a mention in a comment
    # (#338 improve S1 / redmr MAJOR: a `# … source the hermetic-env guard`
    # comment defeats an unanchored match — anchor to `^\s*(.|source)\s`).
    grep -qE '^[[:space:]]*(\.|source)[[:space:]].*hermetic-env' "$layer" || missing+=("$layer")
  done < <(_loaded_layers)
  [ ${#missing[@]} -eq 0 ] || {
    printf 'unguarded setup layer(s) — add `. …/hermetic-env.bash`:\n%s\n' "${missing[@]}" >&2
    false
  }
}

@test "the load-name regex catches a double-quoted load directive (#428)" {
  # #428: a `load "layer"` used to be invisible to _loaded_layers (the regex
  # admitted only bare / single-quoted names), so a double-quoted layer walked
  # past the guard-sourcing invariant. Pin the widened regex with a fixture that
  # exercises all three quoting forms via the shared extractor.
  local tmp; tmp="$(mktemp -d)"
  printf 'load bare-layer\nload '\''single-layer'\''\nload "double-layer"\n' \
    > "$tmp/fixture.bats"

  run _extract_load_names "$tmp/fixture.bats"
  [ "$status" -eq 0 ]
  # The double-quoted name must appear, stripped of its quotes.
  [[ "$output" == *"double-layer"* ]]
  # And all three forms resolve (regression: bare + single still work).
  [[ "$output" == *"bare-layer"* ]]
  [[ "$output" == *"single-layer"* ]]

  rm -rf "$tmp"
}

# --- #585: the BARE-SETUP half of the #322 guard class -----------------------
#
# The #338 canary above covers `load`-ed layers only — its own scope note says so.
# A BARE-SETUP file (no `load` at all) reaches neither arm, which is how
# tests/session-rehydrate.bats ran with an ambient DEVAGENT_ACTIVE_ISSUE able to
# redden 2 of its 6 tests. This arm closes that half of the class.

# Each entry is `<basename>|<reason>` — the reason is MACHINE-CHECKED below, so an
# exemption cannot be added without stating why.
HERMETIC_EXEMPT=(
  'locale-registration.bats|varies LC_ALL on purpose; hermetic-env EXPORTS LC_ALL, so sourcing it disarms the file (see its own header, lines 21-22 and 109)'
)

# Bare basenames of the exemption entries, for membership tests.
_exempt_names() { local e; for e in "${HERMETIC_EXEMPT[@]}"; do printf '%s\n' "${e%%|*}"; done; }

# Every TRACKED tests/*.bats file that `load`s nothing — the population the #338 arm
# cannot reach. Bare filenames; caller resolves against $REPO/tests.
#
# #566: enumerate from the TRACKED set, NUL-delimited. Globbing the working directory
# would let one developer's untracked scratch .bats redden this canary for them and
# nobody else — a test verdict that is a function of the machine, which is the exact
# defect class this file exists to close.
#
# `:(glob)` magic is load-bearing, not decoration. In a DEFAULT git pathspec `*` also
# matches `/`, so a bare `tests/*.bats` reaches into subdirectories and picked up
# tests/fixtures/locale/nonascii.bats — a FIXTURE, not a suite file. Its basename then
# resolved to a $REPO/tests path that does not exist, and the grep below failed with
# "No such file or directory" while the file still counted as unguarded. Under
# `:(glob)`, `*` stops at `/` and the pathspec means what it reads as (measured: 181
# paths without the magic, 180 with).
_bare_setup_files() {
  local f
  while IFS= read -r -d '' f; do
    grep -qE '^[[:space:]]*load[[:space:]]' "$REPO/$f" && continue
    printf '%s\n' "${f##*/}"
  done < <(git -C "$REPO" ls-files -z -- ':(glob)tests/*.bats')
}

# THE predicate, in one place, so the probe below exercises the guard rather than a
# copy of it. Anchored to column 0, which is where the sweep put all 41 of them: the
# leading `[[:space:]]*` this replaced admitted an INDENTED match, including a guard
# line inside `if false; then … fi` (#565: a source grep passes on disabled code), and
# it was already hiding tests/hermetic-env.bats, which matched only on a line inside
# its own test body and so read as guarded while running non-hermetic.
_sources_guard() {
  grep -qE '^(\.|source)[[:space:]].*hermetic-env' "$1"
}

@test "the guard predicate accepts a file-scope source and rejects a disabled one (#585)" {
  # Fixtures, not the real tree: an inline predicate that only ever sees already-correct
  # files cannot show it rejects the wrong ones. Sibling of the shape probe in
  # doctor-hermetic.bats, added for the same reason — a guard that tests a copy of
  # itself is not a guard.
  local t="$BATS_TEST_TMPDIR/f.bats"
  printf '%s\n' '. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"'        > "$t"
  _sources_guard "$t"
  printf '%s\n' 'source "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"'   > "$t"
  _sources_guard "$t"
  # Indented — the shape that let a disabled guard read as present.
  printf '%s\n' '  . "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"'      > "$t"
  run _sources_guard "$t"; [ "$status" -ne 0 ]
  # Inside a disabled branch.
  printf '%s\n%s\n%s\n' 'if false; then' '  . "lib/hermetic-env.bash"' 'fi' > "$t"
  run _sources_guard "$t"; [ "$status" -ne 0 ]
  # Mentioned in a comment only.
  printf '%s\n' '# source lib/hermetic-env.bash here'                   > "$t"
  run _sources_guard "$t"; [ "$status" -ne 0 ]
}

@test "every BARE-SETUP bats file sources the hermetic-env guard (#585)" {
  local missing=() f
  while read -r f; do
    _exempt_names | grep -qx "$f" && continue
    _sources_guard "$REPO/tests/$f" || missing+=("$f")
  done < <(_bare_setup_files)
  # printf repeats its FORMAT once per argument, so a combined header+list would
  # print the header per file. Emit the header once, then the names.
  [ ${#missing[@]} -eq 0 ] || {
    echo 'unguarded bare-setup file(s) — add `. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"`:' >&2
    printf '%s\n' "${missing[@]}" >&2
    false
  }
}

@test "the bare-setup canary actually SELECTS files (not vacuously empty, #151)" {
  # A glob that stops selecting its subjects passes SILENTLY (#439). Assert the
  # subject COUNT is in the expected band and that known members are present.
  local n; n="$(_bare_setup_files | wc -l)"
  [ "$n" -ge 30 ]
  _bare_setup_files | grep -qx 'session-rehydrate.bats'
  _bare_setup_files | grep -qx 'locale-registration.bats'
  # The pathspec must NOT reach into tests/ subdirectories. Without `:(glob)` magic a
  # default git pathspec lets `*` cross `/`, which selected the fixture
  # tests/fixtures/locale/nonascii.bats and then grepped a path that does not exist.
  _bare_setup_files | grep -qx 'nonascii.bats' && {
    echo 'pathspec crossed a directory boundary — restore the :(glob) magic' >&2; false; }
  # Every selected name must resolve to a real file directly under tests/.
  local f
  while read -r f; do [ -f "$REPO/tests/$f" ] || { echo "selected non-existent tests/$f" >&2; false; }; done \
    < <(_bare_setup_files)
  # And the enumerator really is reading git, not the filesystem (#566): a file that
  # exists on disk but is untracked must NOT appear.
  #
  # Run it IN-PROCESS. `run bash -c '_bare_setup_files | …'` cannot work: bash -c
  # starts a fresh shell that has never seen this file's functions, so the pipeline
  # is empty, grep returns 1, and the assertion passes no matter what the enumerator
  # does. That vacuous form let a revert to `printf '%s\0' tests/*.bats` keep all
  # five tests green — the #572 class (a negative assertion satisfied by a missing
  # function), which is why the type probe below comes first.
  run type -t _bare_setup_files
  [ "$output" = function ]

  # Prove the enumerator reads git without WRITING to the tree. The earlier version
  # planted an untracked .bats in tests/ and removed it afterwards; an interrupt
  # between those two points left a stray file that ship.sh's untracked gate refuses
  # on and that the next `bats tests/` collects as real. A subset assertion fails on a
  # filesystem glob for exactly the same reason and touches nothing.
  _bare_setup_files > "$BATS_TEST_TMPDIR/selected.txt"
  git -C "$REPO" ls-files -z -- ':(glob)tests/*.bats' \
    | tr '\0' '\n' | sed 's|.*/||' | sort -u > "$BATS_TEST_TMPDIR/tracked.txt"
  local strays; strays="$(comm -23 <(sort -u "$BATS_TEST_TMPDIR/selected.txt") "$BATS_TEST_TMPDIR/tracked.txt")"
  [ -z "$strays" ] || {
    echo 'enumerator selected files git does not track — it is globbing the filesystem:' >&2
    printf '%s\n' "$strays" >&2
    false
  }
  # Positive control: the negative above is also satisfied by an enumerator that
  # returns nothing at all.
  grep -qx 'session-rehydrate.bats' "$BATS_TEST_TMPDIR/selected.txt"
}

@test "the exemption list is honored AND is not a silent blanket (#585)" {
  # Every exempted name must exist, must actually be bare-setup, and must CARRY A
  # REASON — a stale or reasonless exemption is a hole that reads as a decision.
  local e name reason
  for e in "${HERMETIC_EXEMPT[@]}"; do
    name="${e%%|*}"; reason="${e#*|}"
    [ -f "$REPO/tests/$name" ]
    _bare_setup_files | grep -qx "$name"
    [ "$reason" != "$e" ]              # a `|` was actually present
    [ "${#reason}" -ge 30 ]            # not a placeholder like "n/a"
  done
  # A growing list is a design smell, not a fix. The cap is TWO, so adding a second
  # exemption still passes and adding a THIRD refuses.
  [ "${#HERMETIC_EXEMPT[@]}" -le 2 ]
}
