#!/usr/bin/env bats
# #713 task 2: the trust exit table and message registry. scripts/lib/refusals.sh
# is the one home of both; commands/pull.md carries the same exit table for a
# polling consumer. Siblings (#714, #719, #902) add rows only in refusals.sh.

bats_require_minimum_version 1.5.0   # run --separate-stderr
load 'lib/bats-helpers'

REFUSALS="$PLUGIN_ROOT/scripts/lib/refusals.sh"

# _exit_rows: stdin markdown → `code|id|meaning|owner`, one line per row of the
# table headed `| Code | Id | Meaning | Owner |`. The ONE parser both sides use.
_exit_rows() {
  awk -F'|' '
    /^\| *Code *\| *Id *\| *Meaning *\| *Owner *\|/ { on = 1; next }
    on && /^\|[- |]+\|$/ { next }
    on && /^\|/ {
      out = ""
      for (i = 2; i <= 5; i++) { f = $i; gsub(/^ +| +$/, "", f); gsub(/`/, "", f); out = out (i > 2 ? "|" : "") f }
      print out; next
    }
    on { exit }'
}

@test "registry: pull.md exit table equals refusals.sh" {
  # shellcheck source=/dev/null
  type trust_exit_table 2>/dev/null || source "$REFUSALS"
  local doc lib
  doc="$(_exit_rows < "$PLUGIN_ROOT/commands/pull.md")"
  lib="$(trust_exit_table | _exit_rows)"
  # positive control: the parser finds rows on both sides.
  [ "$(grep -c . <<<"$lib")" -ge 6 ]
  [ "$doc" = "$lib" ] || { diff <(echo "$doc") <(echo "$lib"); false; }
}

@test "registry: pull.md names a consumer action for every code" {
  # shellcheck source=/dev/null
  source "$REFUSALS"
  local code
  for code in $(trust_exit_table | _exit_rows | cut -d'|' -f1); do
    grep -Eq "^- \`$code\` → " "$PLUGIN_ROOT/commands/pull.md" || { echo "no action for $code" >&2; false; }
  done
}

@test "registry: codes are unique and in 6..11" {
  # shellcheck source=/dev/null
  source "$REFUSALS"
  local codes
  codes="$(trust_exit_table | _exit_rows | cut -d'|' -f1)"
  [ "$(sort <<<"$codes" | uniq -d)" = "" ]
  [ "$(sort -n <<<"$codes" | tr '\n' ' ')" = "6 7 8 9 10 11 " ]
}

@test "registry: refuse prints the exact template and exits 9" {
  run --separate-stderr bash -c "source '$REFUSALS'; refuse not-worker github:42"
  [ "$status" -eq 9 ]
  [ "$output" = "" ]
  [ "$stderr" = "bash: trust: account github:42 is not in worker_identities — host-level refusal (exit 9): stop and fix the host; do not retry or work around it" ]
}

@test "registry: try_later prints the exact template and exits 10" {
  run --separate-stderr bash -c "source '$REFUSALS'; try_later whoami-unavailable github.com 75"
  [ "$status" -eq 10 ]
  [ "$stderr" = "bash: trust: whoami could not reach github.com (backend exit 75) — try later (exit 10): a check could not run; retry later" ]
}

@test "registry: trust_warn prints a WARNING line and returns 0" {
  run --separate-stderr bash -c "source '$REFUSALS'; trust_warn user-ignored /home/u/.config/devagent/trust; echo after"
  [ "$status" -eq 0 ]
  [ "$output" = "after" ]
  [ "$stderr" = "bash: trust: WARNING: a user-level policy at /home/u/.config/devagent/trust is ignored: a system policy exists" ]
}

@test "registry: every refusal id has a detail and only the two -unavailable ids are try-laters" {
  # shellcheck source=/dev/null
  source "$REFUSALS"
  local id want
  for id in policy-defect whoami-failed whoami-unavailable whoami-unsupported not-worker \
            trusted-worker hardening-unmet gh-host-bare transition-off scope-unresolved \
            scope-unkeyable yes-refused user-ignored quarantine-unmapped \
            quarantine-label-missing events-unsupported events-unavailable disk-backend; do
    [ -n "${TRUST_REFUSAL_DETAIL[$id]:-}" ] || { echo "no detail for $id" >&2; false; }
  done
  [ "${#TRUST_REFUSAL_DETAIL[@]}" -eq 18 ]
  for id in "${!TRUST_REFUSAL_DETAIL[@]}"; do
    want=9
    case "$id" in whoami-unavailable|events-unavailable) want=10 ;; esac
    [ "$(trust_refusal_code "$id")" = "$want" ] || { echo "$id code" >&2; false; }
  done
}

@test "registry: an unknown refusal id still exits 9" {
  run --separate-stderr bash -c "source '$REFUSALS'; refuse no-such-id x"
  [ "$status" -eq 9 ]
  [[ "$stderr" == *"trust: unknown refusal id 'no-such-id'"* ]]
}

@test "registry: every detail formats cleanly (a leading -- is not an option)" {
  run --separate-stderr bash -c "source '$REFUSALS'; for id in \"\${!TRUST_REFUSAL_DETAIL[@]}\"; do _trust_detail \"\$id\" a b; echo; done"
  [ "$status" -eq 0 ]
  [ "$stderr" = "" ]
  [[ "$output" == *"--yes is refused under a trust policy; the policy's file gate decides"* ]]
}

# #714: rows 6, 7 and 11 are emitted, and their exact text is the decision.
@test "registry: rows 6, 7 and 11 are emitted by #714 (no \"reserved\")" {
  # shellcheck source=/dev/null
  source "$REFUSALS"
  local rows
  rows="$(trust_exit_table | _exit_rows | grep -E '^(6|7|11)[|]')"
  [ "$rows" = "6|quarantined-by-pull|quarantined by this pull|#714
7|pull-quarantined|pull refused: quarantined and not released|#714
11|quarantine-refused|refused on quarantine, every entry point but pull|#714" ] || { echo "$rows" >&2; false; }
}

@test "registry: quarantine_message renders the five fixed lines for a key" {
  run --separate-stderr bash -c "source '$REFUSALS'; quarantine_message github:github.com/acme/widgets#7"
  [ "$status" -eq 0 ]
  [ "$stderr" = "" ]
  [ "$output" = "QUARANTINED: github:github.com/acme/widgets#7 is held for human review.
This is not a stuck step. Nothing in this session can release it:
do not unstick, re-pull, edit, delete, park, resume, revise, switch to, ship or clean up this issue,
and do not change its labels on the tracker. A change made by any worker account does not count.
Release is a tracker action by a trusted approver. Wait for the operator." ]
}

@test "registry: QUARANTINE_REASONS is exactly the 15 issue tokens" {
  # shellcheck source=/dev/null
  source "$REFUSALS"
  [ "${QUARANTINE_REASONS[*]}" = "steering size chars provenance screen screen-failed operator tracker paths destination secrets drift actions diff-size signature" ]
  [ "${#QUARANTINE_REASONS[@]}" -eq 15 ]
}
