#!/usr/bin/env bats
# #966: the pre-post leak gate, scripts/lib/post-gate.sh — the fixture, the
# grammar, the line format, `hash` and the `review` check (Task 4), then the
# `permission` and `tracker` checks and the docs. The `names` check has its own
# files (tests/post-gate-names.bats, tagged for Git Bash, and
# tests/post-gate-modes.bats); post-comment is tests/issue-github-post.bats.
# Every test drives the real entry point under pg_setup's DA_HOME and HOME.

bats_require_minimum_version 1.5.0   # run --separate-stderr
load 'lib/bats-helpers'
load 'lib/post-gate-fixture'
load 'lib/trust-fixture'

setup() {
  pg_setup
}

# The gate suites. Each calls pg_setup in setup(); a file joins this list in the
# task that creates it.
PG_SUITES=(post-gate.bats post-gate-names.bats post-gate-modes.bats issue-github-post.bats)

# _usage <args…>: the call is a usage fault: exit 2, nothing on stdout, and no
# `post-gate:` line.
_usage() {
  pg_run "$PG" "$@"
  [ "$status" -eq 2 ] || { echo "rc=$status for: $*" >&2; echo "$stderr" >&2; return 1; }
  [ -z "$output" ] || { echo "stdout for: $*" >&2; return 1; }
  [ -z "$(pg_gate_lines)" ] || { echo "a post-gate line for: $*" >&2; return 1; }
  [[ "$stderr" == *"post-gate.sh: usage:"* ]] || { echo "no usage line for: $*: $stderr" >&2; return 1; }
}

_review() { pg_run "$PG" check review "${PG_COMMON[@]}" --record "$RECORD" "$@"; }

@test "fixture: every gate suite runs under pg_setup" {
  local f loaded
  for f in "${PG_SUITES[@]}"; do
    [ -f "$PLUGIN_ROOT/tests/$f" ] || { echo "missing suite $f" >&2; false; }
    grep -qE "^load 'lib/post-gate-fixture'" "$PLUGIN_ROOT/tests/$f" || { echo "$f does not load the fixture" >&2; false; }
    awk '/^setup\(\) \{/ { on = 1 } on && /^  pg_setup$/ { hit = 1 } on && /^\}/ { exit } END { exit !hit }' \
      "$PLUGIN_ROOT/tests/$f" || { echo "$f: setup() does not call pg_setup" >&2; false; }
  done
  # the reverse: a suite that loads the fixture is on the list.
  loaded="$(cd "$PLUGIN_ROOT/tests" && grep -lE "^load 'lib/post-gate-fixture'" -- *.bats | sort | tr '\n' ' ')"
  [ "$loaded" = "$(printf '%s\n' "${PG_SUITES[@]}" | sort | tr '\n' ' ')" ] || { echo "loaders: $loaded" >&2; false; }
  [[ "$DA_HOME" == "$BATS_TEST_TMPDIR"/* ]]
  [[ "$HOME" == "$BATS_TEST_TMPDIR"/* ]]
  [ "$(grep -c . "$HOME/.config/denylist.txt")" -eq 1 ]
  [ "$(cat "$HOME/.config/denylist.txt")" = "$PG_CANARY" ]
  # the config names another list, so the default path is read only by mistake.
  [ "$(python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get "$DA_HOME/config.toml" paths.denylist_path)" = "$PG_LIST" ]
  [ "$PG_LIST" != "$HOME/.config/denylist.txt" ]
  [ -z "${GH_HOST+x}" ]
}

@test "fixture: the canary fires when the default path is read" {
  # No [paths] denylist_path: the gate falls back to ~/.config/denylist.txt,
  # which under pg_setup's HOME holds only the canary — and every fixture post
  # carries the canary on line 1. A test that reads the default path by
  # mistake therefore sees this hold instead of a pass.
  pg_post
  # control: under the fixture config the post is clean.
  pg_names --no-record
  pg_passes names
  PG_PATHS=none pg_config
  pg_names --no-record
  pg_holds names names-hit hits=1 lines=1
  # and a recording run records the default path it read.
  pg_names
  pg_holds names names-hit hits=1 lines=1
  [ "$(cat "$PG_RECORDED")" = "$(pg_resolved "$HOME/.config/denylist.txt")" ]
}

@test "fixture: pg_run refuses a line outside the contract and a sentinel on stderr" {
  # the checker can fail: each row is one stderr the contract forbids.
  local row
  while IFS= read -r row; do
    stderr="$row"
    run pg_lines_ok
    [ "$status" -ne 0 ] || { echo "accepted: $row" >&2; false; }
  done <<'ROWS'
post-gate: names hold no-such-cause
post-gate: names hold names-hit hits=0 lines=1
post-gate: names hold names-hit hits=1 lines=zzqsentinel
post-gate: names hold gate-error
post-gate: names hold gate-error some-new-detail
post-gate: review pass with detail
post-gate: scan pass
post-gate: permission hold push-mr
note: the text held ZZQsentinel
ROWS
  while IFS= read -r row; do
    stderr="$row"
    run pg_lines_ok
    [ "$status" -eq 0 ] || { echo "refused: $row" >&2; false; }
  done <<'ROWS'
post-gate: names pass
post-gate: names hold names-hit hits=2 lines=3,7
post-gate: permission hold push-mr project=alpha
post-gate: names hold denylist-empty
post-gate: names hold denylist-empty roster-empty
post-gate: tracker hold gate-error owners-malformed
post-gate: record-denylist refused unattended
some other tool: a line that is not the gate's
ROWS
}

@test "usage: each grammar fault exits 2 with no post-gate line" {
  pg_post; pg_record
  local c=("${PG_COMMON[@]}") rec=(--record "$RECORD")
  _usage
  _usage bogus
  _usage check
  _usage check bogus "${c[@]}" "${rec[@]}"                                          # an unknown check
  _usage check review "${c[@]}" "${rec[@]}" --bogus x                               # an unknown flag
  _usage check review "${c[@]}" "${rec[@]}" stray                                   # a stray word
  _usage check review --project=alpha --issue Issue-7 --file "$POST" "${rec[@]}"    # --flag=value
  _usage check review --project "" --issue Issue-7 --file "$POST" "${rec[@]}"       # an empty value
  _usage check review "${c[@]}" "${rec[@]}" --file "$POST"                          # a repeated flag
  _usage check review "${c[@]}" "${rec[@]}" --draft --draft                         # a repeated switch
  _usage check review "${c[@]}" "${rec[@]}" --capture some-slug                     # both --issue and --capture
  _usage check review --project alpha --file "$POST" "${rec[@]}"                    # neither
  _usage check review --project alpha --issue Issue-7 "${rec[@]}"                   # no --file
  _usage check review --issue Issue-7 --file "$POST" "${rec[@]}"                    # no --project
  _usage check review "${c[@]}" --record                                            # a flag with no value
  _usage check review "${c[@]}"                                                     # review needs --record
  _usage check review "${c[@]}" --draft                                             # --draft needs --record
  _usage check permission "${c[@]}" --backend github                                # permission needs --repo
  _usage check permission "${c[@]}" --repo acme/widgets                             # … and --backend
  _usage check tracker "${c[@]}" --repo acme/widgets --backend github               # tracker needs --backend-script
  _usage check names "${c[@]}" --names-file "$POST"                                 # --names-file is run's
  _usage run "${c[@]}" --repo acme/widgets --backend github --backend-script "$PG_GITHUB"   # run needs --record
  _usage run "${c[@]}" "${rec[@]}"                                                  # … and the tracker flags
  _usage hash
  _usage hash --draft
  _usage hash "$POST" "$POST"
  _usage hash --bogus "$POST"
  _usage record-denylist --project alpha
  _usage record-denylist --project alpha --issue Issue-7 --file "$POST"
  _usage denylist-status extra
  # the work item is checked on every call, by the notifications file's rules.
  _usage check review --project alpha --issue 'Issue 7' --file "$POST" "${rec[@]}"
  _usage check review --project alpha --issue '-7' --file "$POST" "${rec[@]}"
  _usage check review --project alpha --capture 'a/b' --file "$POST" "${rec[@]}"
  _usage check review --project alpha --capture '.hidden' --file "$POST" "${rec[@]}"
  _usage check review --project gamma --issue Issue-7 --file "$POST" "${rec[@]}"    # not a configured project
  # control: the same call without a fault passes, also for a capture.
  _review
  pg_passes review
  pg_run "$PG" check review --project alpha --capture 2026-11-24-some-slug --file "$POST" "${rec[@]}"
  pg_passes review
}

@test "exit: a hold exits trust_exit_code leak-held" {
  pg_post
  local held
  held="$(pg_held)"
  [[ "$held" =~ ^[0-9]+$ ]]
  [ "$held" -ge 12 ]
  _review                      # no record: a hold
  [ "$status" -eq "$held" ]
  [ -z "$output" ]
  # the number is written nowhere in the script: it is read from the registry.
  run grep -nE "(exit|return)[[:space:]]+$held\b" "$PG"
  [ "$status" -eq 1 ]
  grep -q 'trust_exit_code leak-held' "$PG"
}

@test "source: sourcing post-gate.sh sets no shell option and prints nothing" {
  run --separate-stderr bash -c 'before="$-:$(set +o)"; . "$1"; [ "$before" = "$-:$(set +o)" ] && echo same' _ "$PG"
  [ "$status" -eq 0 ]
  [ "$output" = same ]
  [ -z "$stderr" ]
  # and it loads under the options github.sh runs with.
  run --separate-stderr bash -euo pipefail -c '. "$1"; echo "${#POST_GATE_CAUSES[@]}"' _ "$PG"
  [ "$status" -eq 0 ]
  [ "$output" = 14 ]
  [ -z "$stderr" ]
}

# --- hash ---------------------------------------------------------------------

@test "hash: prints sha256sum's digest of the file's bytes" {
  printf 'line one\nline two\n' > "$POST"
  pg_run "$PG" hash "$POST"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" =~ ^[0-9a-f]{64}$ ]]
  local want
  want="$(sha256sum < "$POST")"
  [ "$output" = "${want%% *}" ]
  # bytes, not text: no final newline, a CR and a byte that is not UTF-8.
  printf 'a\r\nb\xff' > "$POST"
  want="$(sha256sum < "$POST")"
  pg_run "$PG" hash "$POST"
  [ "$output" = "${want%% *}" ]
  # --draft on a file with no Parent epic line hashes the same bytes.
  pg_run "$PG" hash --draft "$POST"
  [ "$status" -eq 0 ]
  [ "$output" = "${want%% *}" ]
}

# _draft <parent-epic-line>: a capture draft at $POST.
_draft() {
  printf '%s\n' '# Add a thing' '' "$1" '' '## Motivation' 'Because.' > "$POST"
}
_hash() { "$PG" hash "$@" "$POST"; }

@test "hash --draft: the same value before and after \" (<url>)\" is appended to the Parent epic line" {
  local before after url='https://github.com/acme/widgets/issues/925'
  _draft 'Parent epic: 2026-11-08-some-epic'
  before="$(_hash --draft)"
  [[ "$before" =~ ^[0-9a-f]{64}$ ]]
  _draft "Parent epic: 2026-11-08-some-epic ($url)"
  after="$(_hash --draft)"
  [ "$after" = "$before" ]
  # without --draft the appended URL is an edit like any other.
  [ "$(_hash)" != "$before" ]
  # http as well as https, and a CRLF draft: the CR stays, the URL goes.
  _draft 'Parent epic: 2026-11-08-some-epic (http://tracker.example/i/9)'
  [ "$(_hash --draft)" = "$before" ]
  printf '# T\r\n\r\nParent epic: e\r\n' > "$POST"
  before="$(_hash --draft)"
  printf '# T\r\n\r\nParent epic: e (%s)\r\n' "$url" > "$POST"
  [ "$(_hash --draft)" = "$before" ]
}

@test "hash --draft: any other edit changes the value" {
  local base url='https://github.com/acme/widgets/issues/925' h
  _draft 'Parent epic: 2026-11-08-some-epic'
  base="$(_hash --draft)"
  # a body edit
  _draft 'Parent epic: 2026-11-08-some-epic'; echo 'More.' >> "$POST"
  [ "$(_hash --draft)" != "$base" ]
  # a parenthesis on that line that is not a URL, or is not at its end
  _draft 'Parent epic: 2026-11-08-some-epic (see the epic)'
  [ "$(_hash --draft)" != "$base" ]
  _draft "Parent epic: 2026-11-08-some-epic ($url) and more"
  [ "$(_hash --draft)" != "$base" ]
  _draft "Parent epic: 2026-11-08-some-epic ($url with space)"
  [ "$(_hash --draft)" != "$base" ]
  # a URL appended to a SECOND Parent epic line: only the first is the key
  printf '%s\n' '# Add a thing' '' 'Parent epic: 2026-11-08-some-epic' 'Parent epic: other' > "$POST"
  h="$(_hash --draft)"
  printf '%s\n' '# Add a thing' '' 'Parent epic: 2026-11-08-some-epic' "Parent epic: other ($url)" > "$POST"
  [ "$(_hash --draft)" != "$h" ]
  # the final newline removed
  _draft 'Parent epic: 2026-11-08-some-epic'
  printf '%s' "$(cat "$POST")" > "$POST.tmp" && mv "$POST.tmp" "$POST"
  [ "$(_hash --draft)" != "$base" ]
  # a fenced example above the real line: the example is not the key, so a URL
  # appended to it is an edit, and one appended to the real line is not.
  printf '%s\n' '# T' '' '```' 'Parent epic: example' '```' '' 'Parent epic: real' > "$POST"
  h="$(_hash --draft)"
  printf '%s\n' '# T' '' '```' "Parent epic: example ($url)" '```' '' 'Parent epic: real' > "$POST"
  [ "$(_hash --draft)" != "$h" ]
  printf '%s\n' '# T' '' '```' 'Parent epic: example' '```' '' "Parent epic: real ($url)" > "$POST"
  [ "$(_hash --draft)" = "$h" ]
}

@test "hash: an unreadable file exits 1 with empty stdout" {
  pg_run "$PG" hash "$BATS_TEST_TMPDIR/no-such-file"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  pg_run "$PG" hash --draft "$BATS_TEST_TMPDIR/no-such-file"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  pg_run "$PG" hash "$BATS_TEST_TMPDIR"          # a directory
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "hash: a mode-000 file exits 1 with empty stdout" {
  skip_on_git_bash "chmod 000"
  skip_if_root
  pg_post
  chmod 000 "$POST"
  pg_run "$PG" hash "$POST"
  chmod 600 "$POST"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# --- the review check ---------------------------------------------------------

@test "review: a matching record with Blocking (0) passes" {
  pg_post; pg_record
  _review
  pg_passes review
  [ -z "$output" ]
  # a CRLF record parses: one trailing CR is dropped from each line.
  sed -i $'s/$/\r/' "$RECORD"
  grep -q $'\r$' "$RECORD"
  _review
  pg_passes review
  # a record whose last line has no newline is still read.
  printf 'Reviewed-sha256: %s\n### Blocking (0)' "$("$PG" hash "$POST")" > "$RECORD"
  _review
  pg_passes review
}

@test "review: no record, and a record without Reviewed-sha256, hold review-missing" {
  pg_post
  _review
  pg_holds review review-missing
  pg_record
  sed -i '/^Reviewed-sha256:/d' "$RECORD"
  _review
  pg_holds review review-missing
  pg_record
  sed -i '/^### Blocking/d' "$RECORD"
  _review
  pg_holds review review-missing
  : > "$RECORD"
  _review
  pg_holds review review-missing
}

@test "review: a malformed record holds review-missing" {
  pg_post
  local sha row
  sha="$("$PG" hash "$POST")"
  # _rec <sha-line…> -- <blocking-line…>
  _write() { printf '%s\n' '# Red-team' "$@" > "$RECORD"; }
  _write "Reviewed-sha256: $sha" "Reviewed-sha256: $sha" '### Blocking (0)'      # two hash lines
  _review; pg_holds review review-missing
  _write "Reviewed-sha256: ${sha:0:63}" '### Blocking (0)'                        # 63 digits
  _review; pg_holds review review-missing
  _write "Reviewed-sha256: ${sha^^}" '### Blocking (0)'                           # upper-case hex
  _review; pg_holds review review-missing
  _write "Reviewed-sha256: $sha" '### Blocking (0)' '### Blocking (0)'            # two headings
  _review; pg_holds review review-missing
  _write "Reviewed-sha256: $sha" '### Blocking (N)'                               # the template's literal
  _review; pg_holds review review-missing
  _write "Reviewed-sha256: $sha trailing" '### Blocking (0)'
  _review; pg_holds review review-missing
  _write "Reviewed-sha256:$sha" '### Blocking (0)'                                # no space
  _review; pg_holds review review-missing
  _write "Reviewed-sha256: $sha" '### Blocking (00)'                              # not a plain count
  _review; pg_holds review review-missing
  _write "Reviewed-sha256: $sha" '### Blocking (0) open'
  _review; pg_holds review review-missing
  _write "Reviewed-sha256: $sha" '### Blocking (1234567890)'                      # more than 9 digits
  _review; pg_holds review review-missing
  # control: the well-formed twin passes.
  _write "Reviewed-sha256: $sha" '### Blocking (0)'
  _review; pg_passes review
}

@test "review: a post edited after its review holds review-stale" {
  pg_post; pg_record
  echo 'One more line.' >> "$POST"
  _review
  pg_holds review review-stale
  # stale is reported before blocking.
  pg_post; pg_record "$POST" "$RECORD" 3
  echo 'One more line.' >> "$POST"
  _review
  pg_holds review review-stale
}

@test "review: Blocking (1) holds review-blocking" {
  pg_post; pg_record "$POST" "$RECORD" 1
  _review
  pg_holds review review-blocking
  pg_record "$POST" "$RECORD" 12
  _review
  pg_holds review review-blocking
}

@test "review: a record path that is a directory holds gate-error" {
  pg_post
  mkdir "$RECORD"
  _review
  pg_holds review gate-error review-unreadable
  # a post that cannot be read cannot be hashed.
  rmdir "$RECORD"; pg_record
  rm "$POST"
  _review
  pg_holds review gate-error file-unreadable
}

@test "review: a mode-000 record holds gate-error" {
  skip_on_git_bash "chmod 000"
  skip_if_root
  pg_post; pg_record
  chmod 000 "$RECORD"
  _review
  chmod 600 "$RECORD"
  pg_holds review gate-error review-unreadable
}

@test "review: core-redissue's documented shape parses" {
  pg_post
  local skill="$PLUGIN_ROOT/skills/core-redissue/SKILL.md" shape sha
  # the fenced example under "## Output", as the skill documents it.
  shape="$(awk '/^## Output/ { on = 1 } on && /^```markdown$/ { f = 1; next } f && /^```$/ { exit } f { print }' "$skill")"
  grep -qxF '### Blocking (N)' <<<"$shape"
  grep -qF 'Verdict: ' <<<"$shape"
  sha="$("$PG" hash "$POST")"
  # _shape <n>: the documented shape with a count and the hash line added.
  _shape() {
    { sed "s/^### Blocking (N)\$/### Blocking ($1)/" <<<"$shape"; printf '\nReviewed-sha256: %s\n' "$sha"; } > "$RECORD"
  }
  _shape 0
  _review
  pg_passes review
  _shape 2
  _review
  pg_holds review review-blocking
  # as documented, with no hash line, it is not a record the gate accepts.
  printf '%s\n' "$shape" > "$RECORD"
  _review
  pg_holds review review-missing
}

@test "review --draft: a draft reviewed before the URL append passes after it" {
  _draft 'Parent epic: 2026-11-08-some-epic'
  pg_record --draft
  _draft 'Parent epic: 2026-11-08-some-epic (https://github.com/acme/widgets/issues/925)'
  _review --draft
  pg_passes review
  # without --draft the same pair is stale.
  _review
  pg_holds review review-stale
  # and --draft does not excuse any other edit.
  echo 'More.' >> "$POST"
  _review --draft
  pg_holds review review-stale
}

# --- the permission check -----------------------------------------------------
# alpha: push_mr = true, github acme/widgets. beta: no permissions table (so
# push_mr is false) and no issue source unless a test gives it one.

# _perm [<project> [<repo> [<backend>]]]
_perm() {
  pg_run "$PG" check permission --project "${1:-alpha}" --issue Issue-7 --file "$POST" \
    --repo "${2:-acme/widgets}" --backend "${3:-github}"
}
# _beta_source <section> <backend> <repo> [<push_mr>]: give beta one issue source.
_beta_source() {
  PG_EXTRA="[project.beta.$1]"$'\n'"backend = \"$2\""$'\n'"repo = \"$3\""
  [ -z "${4:-}" ] || PG_EXTRA+=$'\n\n'"[project.beta.permissions]"$'\n'"push_mr = $4"
  pg_config
}
# _policy [<toml-line>…]: a user-level trust policy under the test's HOME.
_policy() { trust_fixture_policy "$HOME/.config/devagent/trust" "$@"; }

@test "permission: push_mr true and no other project on the tracker passes" {
  pg_post
  _perm
  pg_passes permission
  [ -z "$output" ]
  # another project on ANOTHER tracker does not matter, whatever its push_mr.
  _beta_source issue_source github acme/gadgets
  _perm
  pg_passes permission
  # nor does a source of another built-in backend with the same repo string.
  _beta_source issue_source gitlab acme/widgets
  _perm
  pg_passes permission
  # the check makes no backend call.
  [ ! -e "$GH_STUB_ARGV_LOG" ]
}

@test "permission: push_mr false holds push-mr project=alpha" {
  pg_post
  PG_ALPHA_PUSH=false pg_config
  _perm
  pg_holds permission push-mr project=alpha
  # beta has no permissions table at all.
  _perm beta
  pg_holds permission push-mr project=beta
}

@test "permission: another project on the same tracker with push_mr false holds push-mr project=beta" {
  pg_post
  local repo
  for repo in acme/widgets Acme/Widgets github.com/acme/widgets https://github.com/acme/widgets.git; do
    _beta_source issue_source github "$repo"
    _perm
    pg_holds permission push-mr project=beta || { echo "beta repo: $repo" >&2; false; }
  done
  _beta_source issue_source_fork github Acme/Widgets
  _perm
  pg_holds permission push-mr project=beta
  # the target spelled differently reaches the same key.
  _perm alpha https://github.com/ACME/widgets.git
  pg_holds permission push-mr project=beta
  # a custom backend's source naming the same repo counts as well.
  _beta_source issue_source inhouse acme/widgets
  _perm
  pg_holds permission push-mr project=beta
  # control: once beta's own gate is open the post passes.
  _beta_source issue_source github Acme/Widgets true
  _perm
  pg_passes permission
}

@test "permission: DA_YES=1 and DEVAGENT_PERMISSION_PUSH_MR=true open nothing" {
  pg_post
  PG_ALPHA_PUSH=false pg_config
  DA_YES=1 DEVAGENT_PERMISSION_PUSH_MR=true _perm
  pg_holds permission push-mr project=alpha
  _beta_source issue_source github acme/widgets
  DA_YES=1 DEVAGENT_PERMISSION_PUSH_MR=true _perm
  pg_holds permission push-mr project=beta
}

@test "permission: under a trust policy an in-scope project holds trust" {
  pg_post
  _policy
  _perm
  pg_holds permission trust
  # the policy decides before push_mr is read: a closed config gate reads trust too.
  PG_ALPHA_PUSH=false pg_config
  _perm
  pg_holds permission trust
  # in scope through its fork source, whatever the target.
  PG_ALPHA_REPO=other/thing PG_EXTRA=$'[project.alpha.issue_source_fork]\nbackend = "github"\nrepo = "acme/widgets"' pg_config
  _perm alpha other/elsewhere
  pg_holds permission trust
  [ ! -e "$GH_STUB_ARGV_LOG" ]
}

@test "permission: under a trust policy an out-of-scope project naming a scoped repo holds trust" {
  pg_post
  _policy
  # beta has no issue source, so it is out of scope; its own gate is open.
  PG_EXTRA=$'[project.beta.permissions]\npush_mr = true' pg_config
  local repo
  for repo in acme/widgets github.com/acme/widgets https://github.com/Acme/Widgets.git; do
    _perm beta "$repo"
    pg_holds permission trust || { echo "target: $repo" >&2; false; }
  done
  # control: the same project to an unscoped repo is not held by trust.
  _perm beta acme/gadgets
  pg_passes permission
}

@test "permission: under a policy with project and target out of scope, push_mr decides" {
  pg_post
  _policy 'scopes = ["github:github.com/other/thing"]' 'worker_identities = ["github:1001"]'
  _perm
  pg_passes permission
  PG_ALPHA_PUSH=false pg_config
  _perm
  pg_holds permission push-mr project=alpha
  # the cross-project rule still applies out of scope.
  _beta_source issue_source github Acme/Widgets
  _perm
  pg_holds permission push-mr project=beta
}

@test "permission: a policy that fails to load exits 9 with the #713 refusal line" {
  pg_post
  local pol="$HOME/.config/devagent/trust"
  # _refused: exit 9, the refusal line, no post-gate line, nothing on stdout.
  _refused() {
    [ "$status" -eq 9 ] || { echo "rc=$status: $stderr" >&2; return 1; }
    [ -z "$output" ]
    [ -z "$(pg_gate_lines)" ] || { echo "$stderr" >&2; return 1; }
    [[ "$stderr" == *"post-gate.sh: trust: policy "*" — host-level refusal (exit 9): stop and fix the host; do not retry or work around it" ]] \
      || { echo "$stderr" >&2; return 1; }
  }
  mkdir -p "$pol"
  printf 'scopes = [\n' > "$pol/policy.toml"                 # not TOML
  _perm
  _refused
  printf 'scopes = ["github:github.com/acme/widgets"]\nno_such_key = 1\n' > "$pol/policy.toml"
  _perm
  _refused
  # a location defect: the trust location is a dangling link.
  rm -rf "$pol"
  ln -s "$BATS_TEST_TMPDIR/no-such-target" "$pol"
  if [ -L "$pol" ] && [ ! -e "$pol" ]; then
    _perm
    _refused
    [[ "$stderr" == *"dangling link"* ]]
  fi
  # the full run refuses the same way, before any check line.
  rm -f "$pol"; mkdir -p "$pol"
  printf 'scopes = [\n' > "$pol/policy.toml"
  pg_record
  pg_run "$PG" run "${PG_COMMON[@]}" --repo acme/widgets --backend github --backend-script "$PG_GITHUB" --record "$RECORD"
  _refused
}

@test "permission: another project's source that cannot be read holds gate-error config-unreadable" {
  pg_post
  _beta_source issue_source github acme/widgets true
  # beta's source reads fail as a broken config would (rc 2); alpha's do not.
  local script='
    . "$1"; shift
    eval "$(declare -f config_get_project_field | sed "1s/config_get_project_field/_real_field/")"
    config_get_project_field() { if [ "$1" = beta ]; then return "$BETA_RC"; fi; _real_field "$@"; }
    post_gate_check permission "$@"
  '
  BETA_RC=2 pg_run bash -c "$script" _ "$PG" --project alpha --issue Issue-7 --file "$POST" --repo acme/widgets --backend github
  pg_holds permission gate-error config-unreadable
  # control: an absent field (rc 1) is no source, as before.
  BETA_RC=1 pg_run bash -c "$script" _ "$PG" --project alpha --issue Issue-7 --file "$POST" --repo acme/widgets --backend github
  pg_passes permission
}

@test "permission: a repo that cannot be keyed holds gate-error" {
  pg_post
  _perm alpha 'not a repo'
  pg_holds permission gate-error repo-unkeyable
  _perm alpha acme
  pg_holds permission gate-error repo-unkeyable
  # a JIRA key needs the policy's tracker host; with no policy it has no key.
  _perm alpha PROJ jira
  pg_holds permission gate-error repo-unkeyable
  # a backend with no canonical key
  _perm alpha acme/widgets inhouse
  pg_holds permission gate-error repo-unkeyable
  # under a policy too
  _policy
  _perm beta 'not a repo'
  pg_holds permission gate-error repo-unkeyable
}

@test "permission: the check restores the caller's TRUST_IN_SCOPE; under a policy TRUST_VAL ends up the host policy's" {
  pg_post
  # A caller that ran trust_entry_check holds TRUST_IN_SCOPE and the policy's
  # gates; permission_value reads both. With no policy on the host the check
  # overwrites neither.
  run --separate-stderr bash -euo pipefail -c '
    . "$1"; shift
    TRUST_IN_SCOPE=1
    declare -gA TRUST_VAL=([push_mr]=true [marker]=kept)
    post_gate_check permission "$@" || exit 70
    echo "in_scope=$TRUST_IN_SCOPE marker=${TRUST_VAL[marker]:-lost} push_mr=$(permission_value alpha push_mr)"
  ' _ "$PG" --project alpha --issue Issue-7 --file "$POST" --repo acme/widgets --backend github
  [ "$status" -eq 0 ] || { echo "rc=$status $stderr" >&2; false; }
  [ "$output" = "in_scope=1 marker=kept push_mr=true" ]
  [ "$stderr" = "post-gate: permission pass" ]
  # and inside the check the caller's in-scope flag did not make it read the
  # policy's gate in place of the project's.
  PG_ALPHA_PUSH=false pg_config
  pg_run bash -c '
    . "$1"; shift
    TRUST_IN_SCOPE=1
    declare -gA TRUST_VAL=([push_mr]=true)
    post_gate_check permission "$@"
  ' _ "$PG" --project alpha --issue Issue-7 --file "$POST" --repo acme/widgets --backend github
  pg_holds permission push-mr project=alpha
  # Under a policy (project and target out of scope) the flag and the scope
  # list are still the caller's afterwards, but trust_load re-declares TRUST_ID
  # and TRUST_VAL globally: those two then hold the HOST policy's values, as
  # the spec's gate section says. Pinned so the sentence and the code agree.
  pg_config
  _policy 'scopes = ["github:github.com/other/thing"]' 'worker_identities = ["github:1001"]'
  run --separate-stderr bash -euo pipefail -c '
    . "$1"; shift
    TRUST_IN_SCOPE=1
    TRUST_SCOPES=(caller:scope)
    declare -gA TRUST_VAL=([push_mr]=true [marker]=kept)
    post_gate_check permission "$@" || exit 70
    echo "in_scope=$TRUST_IN_SCOPE scopes=${TRUST_SCOPES[*]} marker=${TRUST_VAL[marker]:-lost} policy_push_mr=${TRUST_VAL[push_mr]:-unset}"
  ' _ "$PG" --project alpha --issue Issue-7 --file "$POST" --repo acme/widgets --backend github
  [ "$status" -eq 0 ] || { echo "rc=$status $stderr" >&2; false; }
  [ "$output" = "in_scope=1 scopes=caller:scope marker=lost policy_push_mr=false" ]
  [ "$stderr" = "post-gate: permission pass" ]
}

# --- the tracker check --------------------------------------------------------
# The gh-stub answers whoami with id 1001 and repos/acme/widgets with owner id
# 1001, login acme: an owned tracker, unless a test changes one side.

# _tracker [<repo> [<backend> [<backend-script>]]]
_tracker() {
  pg_run "$PG" check tracker "${PG_COMMON[@]}" --repo "${1:-acme/widgets}" \
    --backend "${2:-github}" --backend-script "${3:-$PG_GITHUB}"
}
# _owners <toml-value>: set the top-level auto_post_owners.
_owners() { PG_TOP="auto_post_owners = $1" pg_config; }
# _owner_id <id>: the repo owner's numeric id, as the stub answers it.
_owner_id() { printf '{"owner":{"login":"acme","id":%s}}\n' "$1" > "$GH_STUB_GATE_DIR/repo.json"; }
# _recorder: a backend script that logs each call; SETTER RECORDER, RECORDER_LOG.
_recorder() {
  RECORDER="$BATS_TEST_TMPDIR/recording-backend.sh" RECORDER_LOG="$BATS_TEST_TMPDIR/recording-backend.log"
  printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' \"\$*\" >> '$RECORDER_LOG'" 'echo 1001' > "$RECORDER"
  chmod +x "$RECORDER"
}

@test "tracker: an owner listed in auto_post_owners passes with no gh call" {
  pg_post
  _owner_id 2002                    # not the account's: only the list can pass it
  _owners '["github:ACME"]'
  _tracker
  pg_passes tracker
  [ "$(pg_gh_calls)" -eq 0 ]
  _tracker Acme/Widgets
  pg_passes tracker
  # an entry names an owner on every host: the grammar has no host part.
  _tracker ghe.example/acme/widgets
  pg_passes tracker
  _tracker https://github.com/acme/widgets.git
  pg_passes tracker
  [ "$(pg_gh_calls)" -eq 0 ]
  # an entry for another owner, or another backend's entry of the same name, lists nothing.
  _owners '["github:acme-corp", "gitlab:acme", "jira:ACME"]'
  _tracker
  pg_holds tracker unowned
}

@test "tracker: an unlisted owner that is the authenticated account passes" {
  pg_post
  _tracker
  pg_passes tracker
  # exactly two calls, both on the repo's host with GH_HOST unset: the owner, then the account.
  [ "$(pg_gh_calls)" -eq 2 ]
  [ "$(sed -n 1p "$GH_STUB_ARGV_LOG")" = "[api] [--hostname] [github.com] [repos/acme/widgets] GH_HOST=<unset>" ]
  [ "$(sed -n 2p "$GH_STUB_ARGV_LOG")" = "[api] [-i] [--hostname] [github.com] [user] GH_HOST=<unset>" ]
  # a list that names other owners changes nothing.
  rm "$GH_STUB_ARGV_LOG"
  _owners '["github:someone-else"]'
  _tracker
  pg_passes tracker
  [ "$(pg_gh_calls)" -eq 2 ]
}

@test "tracker: an unlisted owner that is not the account holds unowned; listing it passes" {
  pg_post
  _owner_id 2002
  _tracker
  pg_holds tracker unowned
  [ "$(pg_gh_calls)" -eq 2 ]
  # an id that merely starts with the account's is another id.
  _owner_id 10010
  _tracker
  pg_holds tracker unowned
  _owners '["github:acme"]'
  _tracker
  pg_passes tracker
}

@test "tracker: a failed lookup holds tracker-unavailable" {
  pg_post
  # a failed repo-owner call
  echo 1 > "$GH_STUB_GATE_DIR/repo.rc"
  _tracker
  pg_holds tracker tracker-unavailable
  rm "$GH_STUB_GATE_DIR/repo.rc"
  # an owner answer with no numeric id (repo-owner exits 5)
  printf '{}\n' > "$GH_STUB_GATE_DIR/repo.json"
  _tracker
  pg_holds tracker tracker-unavailable
  _owner_id 1001
  # whoami exits 3: the credential is refused
  printf '401 Unauthorized\n' > "$GH_STUB_EVENTS_DIR/user.status"
  echo 1 > "$GH_STUB_EVENTS_DIR/user.rc"
  run "$PG_GITHUB" whoami acme/widgets
  [ "$status" -eq 3 ]
  _tracker
  pg_holds tracker tracker-unavailable
  # whoami exits 75: the call could not run
  printf 'none\n' > "$GH_STUB_EVENTS_DIR/user.status"
  run "$PG_GITHUB" whoami acme/widgets
  [ "$status" -eq 75 ]
  _tracker
  pg_holds tracker tracker-unavailable
  rm "$GH_STUB_EVENTS_DIR/user.status" "$GH_STUB_EVENTS_DIR/user.rc"
  # a backend script that is not there, and one that answers something that is not an id
  _tracker acme/widgets github "$BATS_TEST_TMPDIR/no-such-backend.sh"
  pg_holds tracker tracker-unavailable
  printf '%s\n' '#!/usr/bin/env bash' 'echo "not an id"' > "$BATS_TEST_TMPDIR/odd-backend.sh"
  chmod +x "$BATS_TEST_TMPDIR/odd-backend.sh"
  _tracker acme/widgets github "$BATS_TEST_TMPDIR/odd-backend.sh"
  pg_holds tracker tracker-unavailable
  # control: with every lookup answering, the same call passes.
  _tracker
  pg_passes tracker
}

@test "tracker: a GitLab namespace or JIRA key passes only when listed, and the backend script is never run" {
  pg_post
  _recorder
  _owners '["gitlab:grp/sub", "jira:PROJ"]'
  _tracker grp/sub/proj gitlab "$RECORDER"
  pg_passes tracker
  _tracker Grp/Sub/Proj gitlab "$RECORDER"            # namespaces compare lower-cased
  pg_passes tracker
  _tracker grp/sub/deeper/proj gitlab "$RECORDER"     # a subgroup of a listed group is another namespace
  pg_holds tracker unowned
  _tracker grp/proj gitlab "$RECORDER"                # … and so is its parent
  pg_holds tracker unowned
  _tracker PROJ jira "$RECORDER"
  pg_passes tracker
  _tracker proj jira "$RECORDER"                      # JIRA keys compare exactly
  pg_holds tracker unowned
  _tracker OTHER jira "$RECORDER"
  pg_holds tracker unowned
  # a parent group alone does not cover its subgroup.
  _owners '["gitlab:grp"]'
  _tracker grp/sub/proj gitlab "$RECORDER"
  pg_holds tracker unowned
  _tracker grp/proj gitlab "$RECORDER"
  pg_passes tracker
  # nothing listed
  pg_config
  _tracker grp/sub/proj gitlab "$RECORDER"
  pg_holds tracker unowned
  _tracker PROJ jira "$RECORDER"
  pg_holds tracker unowned
  # neither backend has whoami (#900): no call was made, to the script or to gh.
  [ ! -e "$RECORDER_LOG" ]
  [ "$(pg_gh_calls)" -eq 0 ]
  # control: the recorder does log when it is run.
  "$RECORDER" whoami x >/dev/null
  [ -s "$RECORDER_LOG" ]
}

@test "tracker: any other backend holds unowned" {
  pg_post
  _recorder
  _owners '["github:acme", "gitlab:acme", "jira:ACME"]'
  _tracker acme/widgets inhouse "$RECORDER"
  pg_holds tracker unowned
  _tracker /srv/issues disk "$RECORDER"
  pg_holds tracker unowned
  [ ! -e "$RECORDER_LOG" ]
  # the backend name is case-folded, as trust folds it.
  _tracker acme/widgets GitHub
  pg_passes tracker
}

@test "tracker: a malformed auto_post_owners holds gate-error" {
  pg_post
  local v
  for v in '["github:"]' '["bitbucket:x"]' '["acme"]' '"github:acme"' '["github:acme", "gitlab:"]' \
           '["github:-acme"]' '["jira:proj"]' '["github:acme "]' '[7]' '["gitlab:grp//proj"]'; do
    _owners "$v"
    _tracker
    pg_holds tracker gate-error owners-malformed || { echo "value: $v" >&2; false; }
  done
  # checked first, for every backend: also where the list could not matter.
  _owners '["acme"]'
  _tracker acme/widgets inhouse
  pg_holds tracker gate-error owners-malformed
  [ "$(pg_gh_calls)" -eq 0 ]
  # an empty list is a list.
  _owners '[]'
  _tracker
  pg_passes tracker
  # a repo that cannot be keyed has no owner to look up.
  _tracker 'not a repo'
  pg_holds tracker gate-error repo-unkeyable
  _tracker solo gitlab
  pg_holds tracker gate-error repo-unkeyable
}

@test "tracker: a [project.<name>] auto_post_owners is ignored" {
  pg_post
  _owner_id 2002
  PG_ALPHA_KEYS='auto_post_owners = ["github:acme"]' pg_config
  _tracker
  pg_holds tracker unowned
  # the user-level value is the one that is read.
  PG_TOP='auto_post_owners = ["github:acme"]' PG_ALPHA_KEYS='auto_post_owners = ["github:someone-else"]' pg_config
  _tracker
  pg_passes tracker
}

# --- every cause, once, under the options github.sh runs with ------------------

@test "sweep: each cause holds the same way under bash -euo pipefail" {
  pg_post; pg_record
  local c=("${PG_COMMON[@]}") t=(--repo acme/widgets --backend github) other="$BATS_TEST_TMPDIR/lists/other.txt"
  _e() { pg_run bash -euo pipefail "$PG" "$@"; }
  # control: each check passes there.
  _e check permission "${c[@]}" "${t[@]}";           pg_passes permission
  _e check names "${c[@]}" --no-record;              pg_passes names
  _e check review "${c[@]}" --record "$RECORD";      pg_passes review
  # permission: push-mr, gate-error, trust
  PG_ALPHA_PUSH=false pg_config
  _e check permission "${c[@]}" "${t[@]}";           pg_holds permission push-mr project=alpha
  pg_config
  _e check permission "${c[@]}" --repo 'not a repo' --backend github
  pg_holds permission gate-error repo-unkeyable
  _policy
  _e check permission "${c[@]}" "${t[@]}";           pg_holds permission trust
  rm -rf "$HOME/.config/devagent"
  # names: the hit, the five denylist causes, gate-error
  printf 'has %s\n' "$PG_SENTINEL" > "$POST"
  _e check names "${c[@]}" --no-record;              pg_holds names names-hit hits=1 lines=1
  pg_post
  mv "$PG_LIST" "$PG_LIST.away"
  _e check names "${c[@]}";                          pg_holds names denylist-missing-unrecorded
  pg_resolved "$PG_LIST" > "$PG_RECORDED"
  _e check names "${c[@]}";                          pg_holds names denylist-missing
  rm "$PG_RECORDED"
  printf '# nothing\n' > "$PG_LIST"
  _e check names "${c[@]}";                          pg_holds names denylist-empty
  mv "$PG_LIST.away" "$PG_LIST"
  printf '%s\n' "$PG_SENTINEL" > "$other"
  pg_resolved "$other" > "$PG_RECORDED"
  _e check names "${c[@]}";                          pg_holds names denylist-moved
  printf 'a\nb\n' > "$PG_RECORDED"
  _e check names "${c[@]}";                          pg_holds names gate-error record-malformed
  rm "$PG_RECORDED"
  pg_run bash -euo pipefail -c '. "$1"; shift; utf8_locale_is_utf8() { return 1; }; post_gate_check names "$@"' _ "$PG" "${c[@]}"
  pg_holds names no-utf8-locale
  # review: missing, stale, blocking, gate-error
  _e check review "${c[@]}" --record "$BATS_TEST_TMPDIR/no-record.md"
  pg_holds review review-missing
  pg_record "$POST" "$RECORD" 2
  _e check review "${c[@]}" --record "$RECORD";      pg_holds review review-blocking
  echo more >> "$POST"
  _e check review "${c[@]}" --record "$RECORD";      pg_holds review review-stale
  _e check review "${c[@]}" --record "$BATS_TEST_TMPDIR"
  pg_holds review gate-error review-unreadable
  # tracker: unowned, tracker-unavailable, gate-error; and the full run.
  pg_post; pg_record
  local b=(--backend-script "$PG_GITHUB")
  _e check tracker "${c[@]}" "${t[@]}" "${b[@]}";    pg_passes tracker
  printf '{"owner":{"login":"acme","id":2002}}\n' > "$GH_STUB_GATE_DIR/repo.json"
  _e check tracker "${c[@]}" "${t[@]}" "${b[@]}";    pg_holds tracker unowned
  echo 1 > "$GH_STUB_GATE_DIR/repo.rc"
  _e check tracker "${c[@]}" "${t[@]}" "${b[@]}";    pg_holds tracker tracker-unavailable
  rm "$GH_STUB_GATE_DIR/repo.rc"
  printf '{"owner":{"login":"acme","id":1001}}\n' > "$GH_STUB_GATE_DIR/repo.json"
  printf '401 Unauthorized\n' > "$GH_STUB_EVENTS_DIR/user.status"; echo 1 > "$GH_STUB_EVENTS_DIR/user.rc"
  _e check tracker "${c[@]}" "${t[@]}" "${b[@]}";    pg_holds tracker tracker-unavailable
  rm "$GH_STUB_EVENTS_DIR/user.status" "$GH_STUB_EVENTS_DIR/user.rc"
  PG_TOP='auto_post_owners = ["acme"]' pg_config
  _e check tracker "${c[@]}" "${t[@]}" "${b[@]}";    pg_holds tracker gate-error owners-malformed
  pg_config
  _e run "${c[@]}" "${t[@]}" "${b[@]}" --record "$RECORD" --no-record
  [ "$status" -eq 0 ]
  [ "$stderr" = "post-gate: permission pass
post-gate: tracker pass
post-gate: names pass
post-gate: review pass" ]
  # usage and hash keep their exits there as well.
  _e check review "${c[@]}"
  [ "$status" -eq 2 ]
  _e hash "$BATS_TEST_TMPDIR/no-such-file"
  [ "$status" -eq 1 ]
}

# --- documentation ------------------------------------------------------------
# The spec's §9.1 "Leak gate" section is the contract #927, #967 and #968 build
# on; these rows hold its vocabulary equal to the script's.

SPEC="$PLUGIN_ROOT/docs/specs/2026-05-19-devagent-plugin-design.md"

# _between <file> <start-regex> <end-regex>: the lines from the first line that
# matches <start-regex> up to (not including) the next line matching <end-regex>.
_between() {
  awk -v s="$2" -v e="$3" 'on && $0 ~ e { exit } !on && $0 ~ s { on = 1 } on { print }' "$1"
}
# _flat: stdin with every run of whitespace as one space.
_flat() { tr -s '[:space:]' ' '; }
_spec_91() { _between "$SPEC" '^### 9\.1 ' '^### 9\.2 '; }
_spec_gate() { _between "$SPEC" '^#### Leak gate' '^### 9\.2 '; }
# _has <needle>: stdin holds the literal <needle>.
_has() { grep -qF -- "$1" || { echo "missing: $1" >&2; return 1; }; }

@test "docs: §9.1 lists post-comment and repo-owner and names the leak gate as whoami's trust-off caller" {
  local block flat
  # the verb block is the section's first fenced block.
  block="$(_spec_91 | awk '/^```/ { n++; next } n == 1 { print }')"
  grep -qE '^whoami +<repo> ' <<<"$block"                       # control: the block is the verb list
  grep -qE '^repo-owner +<repo> ' <<<"$block"
  grep -qE '^post-comment +<repo> <num> --project <name> \(--issue <issue-dir-name> \| --capture <slug>\) --file <post> --review <record>' <<<"$block"
  flat="$(_spec_91 | _flat)"
  # the trust-off sentence names the one caller and where it is allow-listed.
  _has 'With trust off the only caller is the leak gate (`scripts/lib/post-gate.sh`, #966)' <<<"$flat"
  _has "its \`whoami\` call is on the allow-list of \`tests/events-trust-off.bats\`" <<<"$flat"
  if grep -qF 'With trust off no caller invokes them' <<<"$flat"; then echo "the stale no-caller sentence is still there" >&2; false; fi
  # the allow-list the sentence names does carry the file.
  grep -qF "':!scripts/lib/post-gate.sh'" "$PLUGIN_ROOT/tests/events-trust-off.bats"
}

@test "docs: the spec's gate section carries the line format and every cause token" {
  local gate flat t
  local causes=(trust push-mr unowned tracker-unavailable names-hit denylist-missing-unrecorded
    denylist-missing denylist-empty denylist-moved no-utf8-locale review-missing review-stale
    review-blocking gate-error)
  local details=(config-unreadable path-not-absolute path-not-string record-malformed invalid-utf8
    notify-failed record-failed scan-failed scan-disagree owners-malformed review-unreadable
    repo-unkeyable names-file-malformed file-unreadable list-missing list-empty)
  gate="$(_spec_gate)"
  [ "$(grep -c '' <<<"$gate")" -ge 60 ]                         # control: the section was found
  flat="$(_flat <<<"$gate")"
  # the script's two vocabularies are exactly the lists above …
  run bash -c '. "$1"; printf "%s\n" "${POST_GATE_CAUSES[*]}" "${POST_GATE_ERROR_DETAILS[*]}"' _ "$PG"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "${causes[*]}" ]
  [ "${lines[1]}" = "${details[*]}" ]
  [ "${#causes[@]}" -eq 14 ]
  # … the fixture's line check knows the same details …
  [ "$PG_GATE_ERROR_DETAILS" = "$(IFS='|'; echo "${details[*]}")" ]
  # … and the spec names every one, as code.
  for t in "${causes[@]}" "${details[@]}" roster-empty; do
    _has "\`$t\`" <<<"$flat"
  done
  # the two line forms, the contract regex verbatim, and rendered examples.
  _has 'post-gate: <check> pass' <<<"$gate"
  _has 'post-gate: <check> hold <cause>[ <detail>]' <<<"$gate"
  _has "$PG_LINE_RE" <<<"$gate"
  _has 'post-gate: record-denylist refused (unattended|expect-mismatch)' <<<"$gate"
  _has 'post-gate: names pass' <<<"$gate"
  _has 'post-gate: tracker hold unowned' <<<"$gate"
  _has 'post-gate: names hold names-hit hits=2 lines=3,7' <<<"$gate"
  _has 'post-gate: permission hold push-mr project=<name>' <<<"$gate"
  # every rendered example in the section is a line the fixture's checker accepts.
  stderr="$(grep -E '^post-gate: (permission|tracker|names|review) (pass|hold [a-z])' <<<"$gate" | grep -v '<' || true)"
  [ "$(grep -c . <<<"$stderr")" -ge 4 ]
  pg_lines_ok
  # what the permission check leaves behind, as the code does it (not "as it found it").
  _has 'restores the caller'"'"'s `TRUST_IN_SCOPE`' <<<"$flat"
  _has 'under a policy `TRUST_ID` and `TRUST_VAL` hold the host'"'"'s policy afterwards' <<<"$flat"
  if grep -qF 'and the rest) as it found it' <<<"$flat"; then echo "the gate section still claims the whole trust state is untouched" >&2; false; fi
  # the grammar, the statuses, the record format and the exit id.
  _has 'post-gate.sh run <common> --repo <repo> --backend <name> --backend-script <path> --record <record> [--draft] [--names-file <records>] [--no-record]' <<<"$flat"
  _has 'post-gate.sh record-denylist --project <name> (--issue <issue-dir-name> | --capture <slug>) [--expect <path>]' <<<"$flat"
  for t in absent missing moved empty unrecorded present; do _has "\`$t\`" <<<"$flat"; done
  _has 'Reviewed-sha256: ' <<<"$gate"
  _has '### Blocking (0)' <<<"$gate"
  _has '`leak-held`' <<<"$flat"
  _has 'state/post-gate-denylist-path' <<<"$flat"
  # the id, never the number.
  if grep -qE 'exit(s)? 12|code 12' <<<"$flat"; then echo "the gate section writes the hold exit as a number" >&2; false; fi
}

@test "docs: README and docs/configuration.md name both verbs and both config keys, and no longer say whoami has no caller" {
  local f t row
  for f in "$PLUGIN_ROOT/README.md" "$PLUGIN_ROOT/docs/configuration.md"; do
    for t in '`post-comment`' '`repo-owner`' auto_post_owners denylist_path post-gate.sh; do
      grep -qF -- "$t" "$f" || { echo "$f lacks $t" >&2; false; }
    done
    # both verbs have a row in the issue-backend verb table.
    grep -qE '^\| `repo-owner` +\| `<repo>`' "$f" || { echo "$f: no repo-owner row" >&2; false; }
    grep -qE '^\| `post-comment` +\| `<repo> <num> --project' "$f" || { echo "$f: no post-comment row" >&2; false; }
  done
  row="$(grep -E '^\| `whoami` ' "$PLUGIN_ROOT/README.md")"
  [ -n "$row" ]
  [[ "$row" != *"no caller yet"* ]]
  [[ "$row" == *"leak gate"* ]]
  if grep -qF 'nothing reads them yet' "$PLUGIN_ROOT/docs/configuration.md"; then echo "docs/configuration.md still says nothing reads them" >&2; false; fi
  _flat < "$PLUGIN_ROOT/docs/configuration.md" | _has 'the leak gate asks `whoami` with trust off'
}

@test "docs: §3.1 names post-gate.sh, §3.2 both keys, §3.3 state/post-gate-denylist-path, §3.8 the leak-held id" {
  _between "$SPEC" '^### 3\.1 ' '^### 3\.2 ' | _has 'post-gate.sh'
  _between "$SPEC" '^### 3\.2 ' '^### 3\.3 ' | _has 'auto_post_owners = ["github:<login>"]'
  _between "$SPEC" '^### 3\.2 ' '^### 3\.3 ' | _has 'denylist_path = "~/.config/denylist.txt"'
  _between "$SPEC" '^### 3\.3 ' '^### 3\.4 ' | _flat | _has 'post-gate-denylist-path'
  _between "$SPEC" '^### 3\.8 ' '^## 4\. ' | _flat | _has '`leak-held`'
  # §7.3 already names the gate's audit line (#961 wrote it): still there.
  _between "$SPEC" '^### 7\.3 ' '^### 7\.4 ' | _flat | _has 'the leak gate (#966), whose audit lines are written in interactive sessions too'
  # the requirements file: the delivered half of EI-25, and the gate's code in EI-20.
  local req
  req="$(_flat < "$PLUGIN_ROOT/docs/requirements.md")"
  _has 'EI-25: The operator'"'"'s private name list: devagent'"'"'s leak gate reads it by path only' <<<"$req"
  _has 'EI-20: Refusal exit codes: devagent'"'"'s trust, quarantine and leak-gate refusals' <<<"$req"
  grep -qE '^- \*\*Added: .*\(#966\)\.\*\*' "$PLUGIN_ROOT/changelog.d/966.md"
  [ "$(grep -c '^- ' "$PLUGIN_ROOT/changelog.d/966.md")" -eq 1 ]
}
