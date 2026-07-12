#!/usr/bin/env bats
#
# Canary (#446): every OPERATIVE `scripts/…sh` invocation in commands/ and
# skills/ must go through `${CLAUDE_PLUGIN_ROOT}` (or the unbraced
# `$CLAUDE_PLUGIN_ROOT`) so the plugin works when installed from the marketplace
# cache — where cwd is the USER's project, not the repo, and a bare `scripts/…`
# path either fails ("No such file or directory") or silently runs the project's
# OWN scripts/ dir. This is the single biggest blocker to a second user
# installing devagent.
#
# "Operative" = a call that is actually executed: a `scripts/X.sh` immediately
# followed by an argument (space or quote) — code-fence commands and the
# `Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/X.sh" <args>`` thin-wrapper
# instructions. Bare-filename PROSE mentions (`scripts/X.sh` closed by a
# backtick, e.g. "Invokes `scripts/commit.sh`") are descriptive, never executed,
# and out of scope. The test is the regression gate: a newly-added command that
# forgets ${CLAUDE_PLUGIN_ROOT} on an operative call fails here instead of
# shipping a marketplace-broken command.

ROOT="$BATS_TEST_DIRNAME/.."

# The operative bare-call pattern: `scripts/<name>.sh` followed by a space or
# quote (an argument), NOT preceded by CLAUDE_PLUGIN_ROOT (braced or unbraced).
OPERATIVE_RE='scripts/[a-z_-]+\.sh[ "'"'"']'
CORRECT_RE='CLAUDE_PLUGIN_ROOT[}]?/scripts/'

@test "no operative bare scripts/ invocation in commands/ or skills/ (#446)" {
  [ -d "$ROOT/commands" ]
  [ -d "$ROOT/skills" ]

  # Sanity: the corpus DOES contain correct ${CLAUDE_PLUGIN_ROOT}/scripts calls,
  # so an empty result below means "clean", not "grep/path broken" (#314/#337).
  run grep -rEl "$CORRECT_RE" "$ROOT/commands" "$ROOT/skills"
  [ "$status" -eq 0 ]

  # The canary: capture operative bare calls into a var, then assert emptiness
  # (the #314 shape — never rely on a pipe's swallowed exit status).
  local bare
  bare="$(grep -rnE "$OPERATIVE_RE" "$ROOT/commands" "$ROOT/skills" \
            | grep -vE "$CORRECT_RE" || true)"
  if [ -n "$bare" ]; then
    printf 'operative bare scripts/ calls (missing ${CLAUDE_PLUGIN_ROOT}):\n%s\n' "$bare" >&2
    false
  fi
}
