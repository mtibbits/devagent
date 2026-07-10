#!/usr/bin/env bats
# #338: every setup layer a .bats `load`s MUST source the shared hermetic-env
# guard (#322), so hermeticity has exactly one home and a NEW layer can't skip
# it. Bare-setup file (sources the guard directly, not via a loaded layer).
# Scope note (#338 improve A1): this canary covers `load`-ed layers only. Other
# sourcing mechanisms (e.g. HARNESS=…/skill-fixture-check.sh) are out of its
# reach and out of this issue's scope.
REPO="${BATS_TEST_DIRNAME}/.."
. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

# Resolve every `load X` in tests/*.bats to its helper file (bats adds .bash).
_loaded_layers() {
  grep -rhoE "^[[:space:]]*load[[:space:]]+'?[A-Za-z0-9_./-]+'?" "$REPO"/tests/*.bats \
    | sed -E "s/^[[:space:]]*load[[:space:]]+'?//; s/'?[[:space:]]*$//" \
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
