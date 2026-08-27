#!/usr/bin/env bats
# #425: assert that no script under scripts/ concatenates a `templates/<key>.md`
# path outside the curated resolver/fallback allowlist. Template resolution must
# go through the §12 registry (scripts/lib/template_resolve.sh / artifact.sh); a
# hand-rolled `"$PLUGIN_ROOT/templates/foo.md"` loop is the #341/#423/#424 bypass
# shape that shipped green because nothing asserted this. This canary is that
# assertion.
#
# Discriminator: real path concatenations end `.md"` (a quoted path being built
# into a variable / echoed). Prose and comments (`templates/<key>.md`,
# `templates/wbs_template.md, substituting`) do NOT end in `.md"`, so the trailing
# double-quote anchor separates code from documentation without a comment-stripping
# pass. Do not "simplify" the anchor away — it is load-bearing.
#
# Allowlist (files permitted to concatenate — enumerated by basename, never a whole
# directory, or the canary would be defeated):
#   - scripts/lib/template_resolve.sh  (the canonical §12 resolver)
#   - scripts/lib/artifact.sh          (the other full §12 resolver, artifact_resolve_or)
#   - scripts/lib/checklist.sh         (no-project plugin-default checklist fallback, :25)
# init.sh's `templates/config.toml.skel` is non-.md and excluded by the `.md` anchor.

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

REPO="${BATS_TEST_DIRNAME}/.."

# The one shared FLAG regex + allowlist filter, so the HEAD-green test and the
# planted-violation self-test exercise the SAME logic.
FLAG_RE='templates/[^"]*\.md"'
ALLOWLIST_RE='/(template_resolve|artifact|checklist)\.sh:'

@test "no templates/<key>.md concatenation outside the resolver/fallback allowlist (#425)" {
  run grep -rnE "$FLAG_RE" "$REPO/scripts"
  # rc 0 = matches (the allowlisted concatenations), rc 1 = none, rc 2 = grep error
  # (dir unreadable) which a bare `-ne 0` would false-pass.
  [ "$status" -ne 2 ] || { echo "grep error over scripts/:" >&2; echo "$output" >&2; return 1; }

  local unallowed
  unallowed="$(printf '%s\n' "$output" | grep -vE "$ALLOWLIST_RE" || true)"
  [ -z "$unallowed" ] || {
    echo "template-path concatenation outside the §12 resolver allowlist" >&2
    echo "(route it through scripts/lib/template_resolve.sh — see #341/#423/#424):" >&2
    echo "$unallowed" >&2
    return 1
  }
}

@test "canary logic flags a planted concatenation outside the allowlist (#425)" {
  local tmp
  tmp="$(mktemp -d)"
  # A synthetic non-allowlisted script with a hand-rolled bypass — proves the
  # flag path WITHOUT mutating any tracked file under scripts/.
  cat > "$tmp/statusreport.sh" <<'PLANT'
template="$PLUGIN_ROOT/templates/statusreport_template.md"
PLANT

  run grep -rnE "$FLAG_RE" "$tmp"
  [ "$status" -eq 0 ]                                   # the planted line matched
  local unallowed
  unallowed="$(printf '%s\n' "$output" | grep -vE "$ALLOWLIST_RE" || true)"
  [ -n "$unallowed" ]                                   # and it survived the allowlist filter

  rm -rf "$tmp"
}
