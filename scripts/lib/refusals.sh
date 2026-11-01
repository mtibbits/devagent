#!/usr/bin/env bash
# scripts/lib/refusals.sh — the trust exit table and message registry (#713).
# No dependencies, safe to source multiple times. Siblings (#714, #719, #902)
# add rows HERE only; commands/pull.md carries the same exit table and
# tests/trust-registry.bats holds the two in step.

# trust_exit_table: the exit codes a polling consumer keys on, as markdown rows
# (the shape commands/pull.md carries, read by one parser on both sides).
trust_exit_table() {
  cat <<'EOF'
| Code | Id | Meaning | Owner |
|---|---|---|---|
| 6 | `quarantined-by-pull` | quarantined by this pull — reserved, not emitted until #714 | #714 |
| 7 | `pull-quarantined` | pull refused: quarantined — reserved until #714 | #714 |
| 8 | `held` | held elsewhere — reserved until #719 | #719 |
| 9 | `host` | host-level refusal: identity, policy or environment | #713 |
| 10 | `try-later` | a check could not run (emitted by `whoami` could-not-run) | #713 |
| 11 | `quarantine-refused` | refused on quarantine, other entry points — reserved until #714 | #714 |
EOF
}

# The printf detail of each refusal id. Every id exits 9 except the ones in
# TRUST_REFUSAL_CODE; `user-ignored` is a report line only (doctor, pull's
# run record), never a refusal.
declare -gA TRUST_REFUSAL_DETAIL=(
  [policy-defect]='policy %s: %s'
  [whoami-failed]='whoami failed for %s (backend exit %s)'
  [whoami-unavailable]='whoami could not reach %s (backend exit %s)'
  [whoami-unsupported]='the %s backend has no whoami verb (exit %s); #900 adds it for GitLab and JIRA'
  [not-worker]='account %s is not in worker_identities'
  [trusted-worker]='account %s is in %s; set single_identity = true only if one account is both worker and approver'
  [hardening-unmet]='required_hardening lists %s, which is not met (%s)'
  [gh-host-bare]='GH_HOST is set and %s is a bare OWNER/REPO; a trusted scope needs a host-qualified repo'
  [transition-off]='permissions.transition_issue is not true for project %s; trust needs the quarantine and claim writes'
  [scope-unresolved]='%s could not resolve a project, so its trust scope is unknown'
  [yes-refused]='--yes is refused under a trust policy; the policy'"'"'s file gate decides'
  [user-ignored]='a user-level policy at %s is ignored: a system policy exists'
)
declare -gA TRUST_REFUSAL_CODE=(
  [whoami-unavailable]=10
)

trust_refusal_code() { echo "${TRUST_REFUSAL_CODE[$1]:-9}"; }

# _trust_detail <id> [args…] → the formatted detail on stdout.
_trust_detail() {
  local id="$1" fmt
  shift
  fmt="${TRUST_REFUSAL_DETAIL[$id]:-}"
  if [ -z "$fmt" ]; then
    printf "unknown refusal id '%s'" "$id"
    return 0
  fi
  # shellcheck disable=SC2059  # fmt is a registry entry, never caller text
  printf "$fmt" "$@"
}

# refuse <id> [args…]: a host-level refusal — stderr, exit 9.
refuse() {
  printf '%s: trust: %s — host-level refusal (exit 9): stop and fix the host; do not retry or work around it\n' \
    "$(basename "$0")" "$(_trust_detail "$@")" >&2
  exit 9
}

# try_later <id> [args…]: a check could not run — stderr, exit 10.
try_later() {
  printf '%s: trust: %s — try later (exit 10): a check could not run; retry later\n' \
    "$(basename "$0")" "$(_trust_detail "$@")" >&2
  exit 10
}

# trust_warn <id> [args…]: a WARNING line; returns 0.
trust_warn() {
  printf '%s: trust: WARNING: %s\n' "$(basename "$0")" "$(_trust_detail "$@")" >&2
}
