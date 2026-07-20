#!/usr/bin/env bash
# scripts/lib/baseline.sh — resolve an issue's baseline ref/SHA (#536).
#
# EXTRACTED VERBATIM-IN-BEHAVIOR from branch.sh, which was its sole home and where
# it was inseparable from issue-branch creation. spike.sh (#536) is the second
# consumer: it needs the SAME resolved baseline to cut a throwaway worktree, and a
# second copy of this four-outcome logic would drift (#82).
#
# SHAPE — SETTER-GLOBALS, deliberately NOT a `$(...)` function:
#   * it `die`s on three branches and `warn`s on a fourth, and a die inside command
#     substitution dies only in the SUBSHELL, so the caller sails on (Issue-120);
#   * it returns FOUR values, and side-channel vars do not survive `$(...)` (Issue-282).
# Choose the shape before writing the code — that is the pothole both issues record.
#
# CONTRACT: `baseline_resolve <project> <issue_dir>` sets
#   BASELINE_REF         the ref that was resolved (default_baseline or the #162 override)
#   BASELINE_SHA         its resolved commit SHA
#   BASELINE_OVERRIDE    1 when the per-issue .devagent-baseline override supplied the ref, else 0
#   BASELINE_SOURCE_DIR  the project's source_dir (callers use it AFTER this call —
#                        branch.sh's worktree_root fallback is `$source_dir-wt`, #536 B1)
# and leaves CWD at the source dir (branch.sh has always depended on that `cd`;
# preserved exactly rather than "cleaned up", so the extraction stays behavior-preserving).
#
# Requires the caller to have sourced: io.sh (die/warn), config.sh
# (config_get_project_field), conn-diag.sh (conn_diag_message), and to have
# $DEVAGENT_GIT set. No lib self-sources its deps — that is the house convention.
#
# Source-only file: do not execute directly.

baseline_resolve() {
  local project="$1" issue_dir="$2"
  local baseline source_dir baseline_file baseline_override override_ref
  local base_remote fetch_failed fetch_err baseline_sha cause

  baseline="$(config_get_project_field "$project" default_baseline)"
  source_dir="$(config_get_project_field "$project" source_dir)"

  # Per-issue baseline override (#162). A .devagent-baseline marker in the issue
  # dir (mirroring .devagent-type/.devagent-title) cuts the branch from a
  # non-default base, for issues whose targets live only on an integration branch
  # (e.g. a fork-only harness on dev/all-prs). It is INTENTIONAL: unlike the
  # default-baseline path below it must not silently fall back to HEAD (cf. #72).
  baseline_file="$issue_dir/.devagent-baseline"
  baseline_override=0
  if [ -r "$baseline_file" ]; then
      # Strip all whitespace: a git ref carries none, and this collapses an
      # all-whitespace marker to empty so it is rejected rather than passed on.
      override_ref="$(tr -d '[:space:]' < "$baseline_file")"
      [ -n "$override_ref" ] || die "$baseline_file is empty (no baseline ref)"
      # Treat strictly as a git ref: reject anything outside the ref charset so a
      # marker can never inject shell metacharacters into the git invocations.
      case "$override_ref" in
      *[!A-Za-z0-9._/-]*) die "invalid baseline ref '$override_ref' in $baseline_file (allowed: A-Za-z0-9 . _ / -)" ;;
      esac
      baseline="$override_ref"
      baseline_override=1
  fi

  cd "$source_dir" || die "cannot enter source_dir '$source_dir'"
  # First path component of a remote/branch baseline names the remote to fetch; for
  # a purely local-branch baseline (e.g. dev/all-prs → "dev") it is not a configured
  # remote, so the fetch fails harmlessly — the baseline still resolves locally and
  # fetch_failed is never consulted on that path (see the resolution block below).
  base_remote="$(echo "$baseline" | cut -d/ -f1)"
  # Fetch that remote, but CAPTURE the outcome rather than uniformly absorbing it as
  # "already up to date" (#244). A failed fetch against a *configured* remote means
  # the remote was unreachable (offline, host down, auth, transient), not that the
  # ref is absent — the post-fetch resolution block below uses fetch_failed to tell
  # those apart. stderr is still suppressed so offline tests stay quiet.
  fetch_failed=0
  # #269: capture the fetch stderr (into a var, not the terminal — offline tests stay
  # quiet) so the unreachable-remote die below can classify auth vs network. Order is
  # load-bearing: 2>&1 binds stderr to the capture, THEN 1>/dev/null drops stdout.
  fetch_err="$("$DEVAGENT_GIT" fetch --quiet "$base_remote" 2>&1 1>/dev/null)" || fetch_failed=1
  # Resolve baseline ref.
  if baseline_sha="$("$DEVAGENT_GIT" rev-parse --verify "$baseline" 2>/dev/null)"; then
      :
  elif [ "$baseline_override" -eq 1 ]; then
      # An explicit per-issue override that does not resolve is a hard error —
      # NEVER silently fall back to HEAD or default_baseline (that is the #72
      # mis-base hazard). Fail before any branch is created.
      die "per-issue baseline '$baseline' does not resolve as a git ref in $source_dir; refusing to fall back"
  else
      # Default-baseline path. Three outcomes, not two (#244):
      #  (a) remote NOT configured (offline / no-remote fixture) → fall back to
      #      HEAD, but LOUDLY.
      #  (b) remote configured but the fetch FAILED → the remote was unreachable
      #      (offline, host down, auth, transient). The ref may legitimately exist
      #      remotely; we just never reached it. Do NOT call it pruned/typo'd, and
      #      do NOT fall back to HEAD (would wrong-base on a network blip).
      #  (c) remote configured and the fetch SUCCEEDED but the ref still does not
      #      resolve → genuinely pruned/typo'd/deleted ref.
      # (b) and (c) both refuse a silent HEAD fallback — that is the #72 mis-base
      # hazard: stacking the branch on whatever is checked out (often the previous
      # issue's branch) so ship later bases the PR on the wrong parent.
      if "$DEVAGENT_GIT" remote get-url "$base_remote" >/dev/null 2>&1; then
          if [ "$fetch_failed" -eq 1 ]; then
              # #269: classify the captured fetch stderr (auth vs network vs rate-limit).
              # Ambiguous/unrecognized ⇒ keep today's grouped wording (never mis-assert).
              cause="$(conn_diag_message "$fetch_err" || true)"
              [ -n "$cause" ] || cause="the fetch failed: offline, host down, auth, or transient network error"
              die "default_baseline '$baseline' could not be confirmed — remote '$base_remote' is configured but unreachable ($cause); refusing to fall back to HEAD (would wrong-base) — reconnect and retry, or fix default_baseline if the ref is gone (#72, #244, #269)"
          fi
          die "default_baseline '$baseline' does not resolve though remote '$base_remote' was reached and fetched (pruned, typo'd, or deleted ref?); refusing to fall back to HEAD — fix default_baseline or restore the ref (#72)"
      fi
      warn "default_baseline '$baseline' unresolvable and remote '$base_remote' is not configured; falling back to HEAD ($("$DEVAGENT_GIT" rev-parse --short HEAD)) — the new branch will stack on the current checkout (#72)"
      baseline_sha="$("$DEVAGENT_GIT" rev-parse HEAD)"
  fi

  # shellcheck disable=SC2034  # these four ARE the return channel (setter-globals,
  # see the CONTRACT above) — consumed by branch.sh and spike.sh, not by this file.
  BASELINE_REF="$baseline"
  # shellcheck disable=SC2034  # return channel (see CONTRACT)
  BASELINE_SHA="$baseline_sha"
  # shellcheck disable=SC2034  # return channel (see CONTRACT)
  BASELINE_OVERRIDE="$baseline_override"
  # shellcheck disable=SC2034  # return channel (see CONTRACT)
  BASELINE_SOURCE_DIR="$source_dir"
}
