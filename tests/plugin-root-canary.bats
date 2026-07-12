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
# "Operative" = a call that is actually executed. Two forms are gated:
#   (A) a `scripts/<sub>/<name>.sh` immediately followed by an argument (space or
#       quote) — code-fence commands and `Run `bash "…/scripts/X.sh" <args>``
#       wrapper instructions, INCLUDING subdirectory paths (scripts/capture/…);
#   (B) a command at line start (`scripts/…` or `bash|sh scripts/…`), which
#       covers a zero-arg code-fence call too.
# The `<sub>/` segment matters: the original pattern used `[a-z_-]+` which cannot
# cross a `/`, so it was blind to scripts/capture/reap.sh & friends (the #446
# review catch). Subdir paths are now covered.
#
# Bare-filename PROSE mentions (`scripts/X.sh` closed by a backtick, e.g.
# "Invokes `scripts/commit.sh`", or a source cite `scripts/lib/state.sh:170`) are
# descriptive, never executed, and out of scope. KNOWN RESIDUAL: an inline
# backtick ZERO-arg imperative wrapper (`run `scripts/foo.sh``) is indistinguish-
# able by pattern from prose and is not gated — every real command takes args, so
# this is a review-caught edge, not a mechanical one.

ROOT="$BATS_TEST_DIRNAME/.."

CORRECT_RE='CLAUDE_PLUGIN_ROOT[}]?/scripts/'
# (A) arg-bearing, subdirectory-aware:
OPERATIVE_ARG_RE='scripts/[a-z0-9_/-]+\.sh[ "'"'"']'
# (B) command at line start (optional bash/sh prefix), subdirectory-aware:
OPERATIVE_LINESTART_RE='^[[:space:]]*(bash |sh )?scripts/[a-z0-9_/-]+\.sh'

@test "no operative bare scripts/ invocation in commands/ or skills/ (#446)" {
  [ -d "$ROOT/commands" ]
  [ -d "$ROOT/skills" ]

  # Sanity: the corpus DOES contain correct ${CLAUDE_PLUGIN_ROOT}/scripts calls,
  # so an empty result below means "clean", not "grep/path broken" (#314/#337).
  run grep -rEl "$CORRECT_RE" "$ROOT/commands" "$ROOT/skills"
  [ "$status" -eq 0 ]

  # The canary: capture operative bare calls (both forms) into a var, then assert
  # emptiness (the #314 shape — never rely on a pipe's swallowed exit status).
  local bare
  bare="$( { grep -rnE "$OPERATIVE_ARG_RE" "$ROOT/commands" "$ROOT/skills"
             grep -rnE "$OPERATIVE_LINESTART_RE" "$ROOT/commands" "$ROOT/skills"
           } | grep -vE "$CORRECT_RE" | sort -u || true)"
  if [ -n "$bare" ]; then
    printf 'operative bare scripts/ calls (missing ${CLAUDE_PLUGIN_ROOT}):\n%s\n' "$bare" >&2
    false
  fi
}
