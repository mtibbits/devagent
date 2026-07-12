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
