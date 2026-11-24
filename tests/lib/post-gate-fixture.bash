# tests/lib/post-gate-fixture.bash — the leak gate's shared fixture (#966).
# Load after lib/bats-helpers. Every gate suite calls pg_setup in setup().
#
# pg_setup isolates four things a gate run reads:
#   DA_HOME  a fresh devagent home under the test's temp dir;
#   HOME     a temp dir whose DEFAULT denylist (~/.config/denylist.txt) holds
#            one canary entry. The fixture config names another list, and
#            pg_post writes the canary on line 1 of every post, so a run that
#            falls back to the default path holds `names-hit` on line 1;
#   PATH     the gh-stub first, whoami id 1001, repo owner id 1001;
#   GH_HOST  unset.
# Every private name here is synthesised and starts `zzq`, so pg_run can refuse
# any stderr that holds one.

. "$(dirname "${BASH_SOURCE[0]}")/hermetic-env.bash"   # idempotent (#322)

PG="$PLUGIN_ROOT/scripts/lib/post-gate.sh"
PG_GITHUB="$PLUGIN_ROOT/scripts/issue/github.sh"
PG_CANARY=zzqcanary       # the one entry of the default-path list
PG_SENTINEL=zzqsentinel   # the one entry of the fixture list

# The two helpers are file-local elsewhere (tests/lib_notify.bats,
# tests/disk-issue.bats); the gate suites share these.
is_git_bash() { case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac; return 1; }
# skip_on_git_bash <reason>: Git Bash on NTFS has no POSIX file modes.
skip_on_git_bash() { if is_git_bash; then skip "$1 (Git Bash: no POSIX file modes)"; fi; }
# skip_if_root: root reads a mode-000 file, so a mode-based row proves nothing.
skip_if_root() { if [ "$(id -u)" = 0 ]; then skip "root reads mode-000 files"; fi; }

# The 14 cause tokens and the fixed gate-error details, listed here on purpose
# rather than read from post-gate.sh: pg_run checks the script against them.
PG_GATE_ERROR_DETAILS='config-unreadable|path-not-absolute|path-not-string|record-malformed|invalid-utf8|notify-failed|record-failed|scan-failed|scan-disagree|owners-malformed|review-unreadable|repo-unkeyable|names-file-malformed|file-unreadable|list-missing|list-empty'
# The contract's line regex (spec §9.1), as callers may rely on it.
PG_LINE_RE='^post-gate: (permission|tracker|names|review) (pass|hold (trust|push-mr|unowned|tracker-unavailable|names-hit|denylist-missing-unrecorded|denylist-missing|denylist-empty|denylist-moved|no-utf8-locale|review-missing|review-stale|review-blocking|gate-error)( .+)?)$'
# The same lines with every detail pinned: a cause carries its fixed detail or none.
PG_STRICT_RE='^post-gate: (permission|tracker|names|review) (pass|hold (trust|push-mr project=[A-Za-z0-9._-]+|unowned|tracker-unavailable|names-hit hits=[1-9][0-9]* lines=[1-9][0-9]*(,[1-9][0-9]*)*|denylist-missing-unrecorded|denylist-missing|denylist-empty( roster-empty)?|denylist-moved|no-utf8-locale|review-missing|review-stale|review-blocking|gate-error ('"$PG_GATE_ERROR_DETAILS"')))$'
PG_REFUSED_RE='^post-gate: record-denylist refused (unattended|expect-mismatch)$'

# pg_held: the leak-held exit code, read from the registry by id.
pg_held() { ( . "$PLUGIN_ROOT/scripts/lib/refusals.sh"; trust_exit_code leak-held ); }

# pg_config: (re)write $DA_HOME/config.toml from these knobs:
#   PG_TOP         lines above the first table (e.g. auto_post_owners = [...])
#   PG_PATHS       the [paths] table's lines; default names the fixture list;
#                  `none` writes no [paths] table
#   PG_ALPHA_PUSH  alpha's permissions.push_mr (default true)
#   PG_ALPHA_REPO  alpha's issue_source.repo (default acme/widgets)
#   PG_EXTRA       lines appended after both projects
pg_config() {
  local paths="${PG_PATHS:-denylist_path = \"$PG_LIST\"}"
  {
    [ -z "${PG_TOP:-}" ] || printf '%s\n\n' "$PG_TOP"
    [ "$paths" = none ] || printf '[paths]\n%s\n\n' "$paths"
    cat <<TOML
[project.alpha]
source_dir = "$BATS_TEST_TMPDIR/src/alpha"
devdoc_dir = "$BATS_TEST_TMPDIR/devDoc/alpha"

[project.alpha.permissions]
push_mr = ${PG_ALPHA_PUSH:-true}

[project.alpha.issue_source]
backend = "github"
repo = "${PG_ALPHA_REPO:-acme/widgets}"

[project.beta]
source_dir = "$BATS_TEST_TMPDIR/src/beta"
devdoc_dir = "$BATS_TEST_TMPDIR/devDoc/beta"
TOML
    [ -z "${PG_EXTRA:-}" ] || printf '\n%s\n' "$PG_EXTRA"
  } > "$DA_HOME/config.toml"
}

pg_setup() {
  export DA_HOME="$BATS_TEST_TMPDIR/da"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$DA_HOME/state" "$HOME/.config" "$BATS_TEST_TMPDIR/lists"
  printf '%s\n' "$PG_CANARY" > "$HOME/.config/denylist.txt"
  PG_LIST="$BATS_TEST_TMPDIR/lists/denylist.txt"
  printf '%s\n' '# the fixture denylist' "$PG_SENTINEL" > "$PG_LIST"
  PG_RECORDED="$DA_HOME/state/post-gate-denylist-path"
  PG_NOTIFY="$DA_HOME/state/notifications.jsonl"
  unset PG_TOP PG_PATHS PG_ALPHA_PUSH PG_ALPHA_REPO PG_EXTRA
  pg_config
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cp "$PLUGIN_ROOT/tests/fixtures/gh-stub" "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
  export GH_STUB_CASE=standard GH_STUB_ARGV_LOG="$BATS_TEST_TMPDIR/gh-argv.log"
  export GH_STUB_EVENTS_DIR="$BATS_TEST_TMPDIR/gh-events" GH_STUB_GATE_DIR="$BATS_TEST_TMPDIR/gh-gate"
  mkdir -p "$GH_STUB_EVENTS_DIR" "$GH_STUB_GATE_DIR"
  printf '%s\n' '{"login":"worker","id":1001,"type":"User"}' > "$GH_STUB_EVENTS_DIR/user.json"
  printf '%s\n' '{"name":"widgets","owner":{"login":"acme","id":1001}}' > "$GH_STUB_GATE_DIR/repo.json"
  unset GH_HOST DA_YES DEVAGENT_PERMISSION_PUSH_MR
  POST="$BATS_TEST_TMPDIR/post.md"
  RECORD="$BATS_TEST_TMPDIR/redteam.md"
  # the <common> flags for the fixture post.
  PG_COMMON=(--project alpha --issue Issue-7 --file "$POST")
}

# pg_post [<file>]: a clean post. Line 1 carries the canary, which no fixture
# list holds, so it is clean unless a run read the default path.
pg_post() {
  printf '%s\n' "$PG_CANARY marker" '' 'A clean comment body.' 'Second line.' > "${1:-$POST}"
}

# pg_record [--draft] [<post> [<record> [<blocking>]]]: a review record for
# <post>, hashed with the real `post-gate.sh hash` (the value the gate compares).
pg_record() {
  local draft=() post rec n sha
  if [ "${1:-}" = --draft ]; then draft=(--draft); shift; fi
  post="${1:-$POST}" rec="${2:-$RECORD}" n="${3:-0}"
  sha="$("$PG" hash "${draft[@]}" "$post")" || return 1
  printf '%s\n' '# Red-team — fixture' '' 'Run: 2026-11-24 10:00' '' "Reviewed-sha256: $sha" '' \
    "### Blocking ($n)" '' '### Recommended (0)' '' '### Nits (0)' '' 'Verdict: ship' > "$rec"
}

# pg_lines_ok: every `post-gate:` line of $stderr matches the contract regex
# and its pinned-detail form (or the record-denylist refusal), and $stderr
# holds no sentinel.
pg_lines_ok() {
  local line
  while IFS= read -r line; do
    [[ "$line" == post-gate:* ]] || continue
    if [[ "$line" =~ $PG_REFUSED_RE ]]; then continue; fi
    if ! [[ "$line" =~ $PG_LINE_RE ]] || ! [[ "$line" =~ $PG_STRICT_RE ]]; then
      echo "pg_run: a post-gate line is outside the contract: $line" >&2
      return 1
    fi
  done <<<"$stderr"
  if grep -qi zzq <<<"$stderr"; then
    echo "pg_run: stderr holds a sentinel" >&2
    return 1
  fi
}

# pg_run <command…>: run an entry point with stdout and stderr apart, then fail
# the test on a line outside the contract or a sentinel on stderr.
pg_run() {
  run --separate-stderr "$@"
  pg_lines_ok
}

# pg_gate_lines: the `post-gate:` lines of $stderr, in order.
pg_gate_lines() { grep '^post-gate:' <<<"$stderr" || true; }

# pg_holds <check> <cause…>: the last run held with exactly this line, as its
# only hold and its last gate line, and exited the leak-held code.
pg_holds() {
  local check="$1"; shift
  [ "$status" -eq "$(pg_held)" ] || { echo "rc=$status, want leak-held; stderr: $stderr" >&2; return 1; }
  [ "$(pg_gate_lines | grep -c ' hold ')" -eq 1 ] || { echo "holds: $stderr" >&2; return 1; }
  [ "$(pg_gate_lines | tail -n 1)" = "post-gate: $check hold $*" ] || { echo "want '$check hold $*', got: $stderr" >&2; return 1; }
}

# pg_passes <check>: the last run exited 0 with that check's pass line as its
# only gate line.
pg_passes() {
  [ "$status" -eq 0 ] || { echo "rc=$status; stderr: $stderr" >&2; return 1; }
  [ "$(pg_gate_lines)" = "post-gate: $1 pass" ] || { echo "want '$1 pass', got: $stderr" >&2; return 1; }
}

# pg_names [<flags>…]: the names check on the fixture post.
pg_names() { pg_run "$PG" check names "${PG_COMMON[@]}" "$@"; }

# pg_resolved <path>: the spelling the gate records for <path>.
pg_resolved() { printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd -P)" "$(basename "$1")"; }

# pg_probe <verb> <args…>: tests/helpers/notify_probe.py on the notifications file.
pg_probe() { python3 -X utf8 "$PLUGIN_ROOT/tests/helpers/notify_probe.py" "$@"; }

# pg_notify_count: the lines of the notifications file (0 when there is none).
pg_notify_count() { if [ -e "$PG_NOTIFY" ]; then pg_probe count "$PG_NOTIFY"; else printf 0; fi; }
