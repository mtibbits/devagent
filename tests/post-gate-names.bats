#!/usr/bin/env bats
# bats file_tags=gitbash
# #966: the leak gate's `names` check, the recorded denylist path,
# `record-denylist` and `denylist-status` (scripts/lib/post-gate.sh). Tagged for
# the Git Bash job: the scan leans on grep's case folding, word boundaries and
# `-f -` under a pinned UTF-8 locale, and on path identity, all of which differ
# by platform. Rows that need POSIX file modes live in the untagged
# tests/post-gate-modes.bats, so no test here is skipped on Windows.
#
# Every private name is synthesised and starts `zzq`; pg_run fails a test whose
# stderr holds one. The Git Bash job's first run records per-test times
# (`bats --timing`); the notify row below is the slow one there.

bats_require_minimum_version 1.5.0   # run --separate-stderr
load 'lib/bats-helpers'
load 'lib/post-gate-fixture'

setup() {
  pg_setup
}

# _list <line…>: rewrite the fixture denylist.
_list() { printf '%s\n' "$@" > "$PG_LIST"; }
# _text <line…>: rewrite the post.
_text() { printf '%s\n' "$@" > "$POST"; }
# _hits <entry> <text-line>: one entry, one line: the names check holds on line 1.
_hits() {
  _list "$1"; _text "$2"
  pg_names --no-record
  pg_holds names names-hit hits=1 lines=1
}
# _misses <entry> <text-line>: … and passes.
_misses() {
  _list "$1"; _text "$2"
  pg_names --no-record
  pg_passes names
}
_status() { pg_run "$PG" denylist-status; }
_record() { pg_run "$PG" record-denylist --project alpha --issue Issue-7 "$@"; }
# _state_listing: the state directory, names and sizes, for "nothing was written".
_state_listing() { (cd "$DA_HOME/state" && ls -la . | sed 1d | awk '{ print $1, $5, $NF }'); }

@test "names: a sentinel holds names-hit with hits and lines" {
  _text one two "has $PG_SENTINEL here, and $PG_SENTINEL again" four five six "and ${PG_SENTINEL^^} in upper case" eight
  pg_names
  pg_holds names names-hit hits=2 lines=3,7
  [ -z "$output" ]
  # the first and the last line, and a last line with no newline.
  printf '%s\nmiddle\n%s' "$PG_SENTINEL" "x $PG_SENTINEL" > "$POST"
  pg_names
  pg_holds names names-hit hits=2 lines=1,3
  # a clean post passes.
  pg_post
  pg_names
  pg_passes names
}

@test "names: the citation form holds" {
  _text 'first' "- a lesson ($PG_SENTINEL Issue-4)." 'last'
  pg_names
  pg_holds names names-hit hits=1 lines=2
  _text "- upper (${PG_SENTINEL^^} Issue-Fork-12; devagent Issue-3)."
  pg_names
  pg_holds names names-hit hits=1 lines=1
}

@test "names: bash -x prints trace lines and never the sentinel" {
  _text one "has $PG_SENTINEL here" three
  pg_run bash -x "$PG" check names "${PG_COMMON[@]}"
  pg_holds names names-hit hits=1 lines=2
  grep -q '^+ ' <<<"$stderr"
  # (pg_run already failed the test if stderr held a zzq name.)
  pg_post
  pg_run bash -x "$PG" check names "${PG_COMMON[@]}"
  pg_passes names
  grep -q '^+ ' <<<"$stderr"
  # control: the trace is live up to the gate — it shows the call's own argv.
  grep -qF -- '--project alpha' <<<"$stderr"
}

@test "names: a CRLF denylist, and a last entry with no newline, still hold" {
  _text "has $PG_SENTINEL here"
  printf '# a list saved on Windows\r\n\r\n  %s  \r\n' "$PG_SENTINEL" > "$PG_LIST"
  pg_names
  pg_holds names names-hit hits=1 lines=1
  printf 'zzqother\n%s' "$PG_SENTINEL" > "$PG_LIST"
  pg_names
  pg_holds names names-hit hits=1 lines=1
  # control: the same post under a list that lacks the name passes.
  printf 'zzqother\r\n' > "$PG_LIST"
  pg_names
  pg_passes names
}

@test "names: a configured project's name and a \"# public:\" name do not hold" {
  # alpha and beta are configured projects; two names share one public line.
  _list '# public: zzqpub1 zzqpub2' ALPHA beta zzqpub1 ZzqPub2 "$PG_SENTINEL"
  _text 'the alpha project and Beta too' 'zzqpub1 is public, and so is ZZQPUB2'
  pg_names
  pg_passes names
  # control: without the public line both names hold.
  _list ALPHA beta zzqpub1 ZzqPub2 "$PG_SENTINEL"
  pg_names
  pg_holds names names-hit hits=1 lines=2
  # a multi-word entry cannot be made public: the line is split on spaces.
  _list '# public: zzq acme corp' 'zzq acme corp'
  _text 'Zzq Acme Corp'
  pg_names
  pg_holds names names-hit hits=1 lines=1
}

@test "names: a roster emptied by project and public names holds denylist-empty roster-empty" {
  pg_post
  _list alpha Beta
  pg_names
  pg_holds names denylist-empty roster-empty
  _list '# public: zzqpub1' zzqpub1 alpha
  pg_names
  pg_holds names denylist-empty roster-empty
  # control: one more entry and the same post passes.
  _list alpha Beta zzqother
  pg_names
  pg_passes names
}

@test "names: multi-word, punctuated and non-ASCII entries match case-insensitively as whole words" {
  local e_lower=$'zzq\xc3\xa9cole' e_upper=$'ZZQ\xc3\x89COLE'
  _hits 'zzq acme corp' 'filed for Zzq Acme Corp today'
  _hits "zzq-o'neil&sons" "see ZZQ-O'NEIL&SONS (the firm)"
  _hits "$e_lower" "at $e_upper."
  _hits "$e_upper" "at $e_lower."
  _misses "$e_lower" "at x${e_lower}x."
  _misses zzqcaf $'the zzqcaf\xc3\xa9 opens'
  _hits zzqcaf 'the zzqcaf opens'
  # a whole word: a longer word that contains the entry is not a hit.
  _misses zzqname 'the zzqnames list'
  # Documented residuals of a line-based whole-word scan (spec §9.1): `_` and
  # digits are word constituents, and an entry split or re-spaced is not seen.
  _misses zzqname 'call zzqname_api and zzqname2'
  _misses 'zzq acme corp' 'filed for zzq  acme corp'
  _list 'zzq acme corp'; _text 'filed for zzq acme' 'corp today'
  pg_names --no-record
  pg_passes names
}

@test "names: each denylist cause holds with its exact token" {
  pg_post
  local other="$BATS_TEST_TMPDIR/lists/other.txt"
  # no file and no record
  rm "$PG_LIST"
  pg_names
  [ "$stderr" = "post-gate: names hold denylist-missing-unrecorded" ]
  pg_holds names denylist-missing-unrecorded
  # a record and no file
  pg_resolved "$PG_LIST" > "$PG_RECORDED"
  pg_names
  [ "$stderr" = "post-gate: names hold denylist-missing" ]
  pg_holds names denylist-missing
  # a directory at the path cannot be read as a list: with a record, and without
  mkdir "$PG_LIST"
  pg_names
  [ "$stderr" = "post-gate: names hold denylist-missing" ]
  rm "$PG_RECORDED"
  pg_names
  [ "$stderr" = "post-gate: names hold denylist-missing-unrecorded" ]
  rmdir "$PG_LIST"
  # a list of comments, blanks and a "# public:" line
  _list '# only comments' '' '   ' '# public: zzqpub1'
  pg_names
  [ "$stderr" = "post-gate: names hold denylist-empty" ]
  pg_holds names denylist-empty
  : > "$PG_LIST"
  pg_names
  [ "$stderr" = "post-gate: names hold denylist-empty" ]
  # a pre-seeded different recorded path
  _list "$PG_SENTINEL"
  printf '%s\n' "$PG_SENTINEL" > "$other"
  pg_resolved "$other" > "$PG_RECORDED"
  pg_names
  [ "$stderr" = "post-gate: names hold denylist-moved" ]
  pg_holds names denylist-moved
  # moved is checked before missing: a config repointed to a file that is not
  # there, while the recorded list still exists, is a move.
  PG_PATHS="denylist_path = \"$BATS_TEST_TMPDIR/lists/gone.txt\"" pg_config
  pg_names
  [ "$stderr" = "post-gate: names hold denylist-moved" ]
  # … also when its directory is missing.
  PG_PATHS="denylist_path = \"$BATS_TEST_TMPDIR/no-such-dir/list.txt\"" pg_config
  pg_names
  [ "$stderr" = "post-gate: names hold denylist-moved" ]
  # a missing directory, recorded under that same spelling, is missing; with no record, unrecorded.
  printf '%s\n' "$BATS_TEST_TMPDIR/no-such-dir/list.txt" > "$PG_RECORDED"
  pg_names
  [ "$stderr" = "post-gate: names hold denylist-missing" ]
  rm "$PG_RECORDED"
  pg_names
  [ "$stderr" = "post-gate: names hold denylist-missing-unrecorded" ]
}

@test "names: no UTF-8 locale holds no-utf8-locale" {
  pg_post
  # The probe is injected by redefining the function, never through the
  # environment: the gate names its candidates and ignores the ambient locale.
  pg_run bash -c '. "$1"; shift; utf8_locale_is_utf8() { return 1; }; post_gate_check names "$@"' _ "$PG" "${PG_COMMON[@]}"
  [ "$stderr" = "post-gate: names hold no-utf8-locale" ]
  pg_holds names no-utf8-locale
  [ ! -e "$PG_RECORDED" ]
  # control: the same sourced call without the redefinition passes, also under
  # an ambient C locale.
  LC_ALL=C LANG=C pg_run bash -c '. "$1"; shift; post_gate_check names "$@"' _ "$PG" "${PG_COMMON[@]}" --no-record
  pg_passes names
}

@test "names: a denylist_path that is not an absolute string, a broken config and a malformed record hold gate-error" {
  pg_post
  # a table where the string belongs must not fall back to the default list.
  PG_PATHS=none PG_EXTRA=$'[paths.denylist_path]\nx = 1' pg_config
  pg_names
  pg_holds names gate-error path-not-string
  PG_PATHS='denylist_path = ["/a/list.txt"]' pg_config
  pg_names
  pg_holds names gate-error path-not-string
  PG_PATHS='denylist_path = "lists/denylist.txt"' pg_config
  pg_names
  pg_holds names gate-error path-not-absolute
  PG_PATHS='denylist_path = ""' pg_config
  pg_names
  pg_holds names gate-error path-not-absolute
  PG_PATHS='denylist_path = 5' pg_config
  pg_names
  pg_holds names gate-error path-not-absolute
  [ ! -e "$PG_RECORDED" ]
  # a config that does not parse
  printf '[paths\n' > "$DA_HOME/config.toml"
  pg_names
  pg_holds names gate-error config-unreadable
  # a record file that is not one line
  pg_config
  printf '%s\n%s\n' "$(pg_resolved "$PG_LIST")" /another/line > "$PG_RECORDED"
  pg_names
  pg_holds names gate-error record-malformed
  : > "$PG_RECORDED"
  pg_names
  pg_holds names gate-error record-malformed
  printf 'relative/path\n' > "$PG_RECORDED"
  pg_names
  pg_holds names gate-error record-malformed
  rm "$PG_RECORDED"; mkdir "$PG_RECORDED"
  pg_names
  pg_holds names gate-error record-malformed
}

@test "names: a [project.<name>] denylist_path is ignored" {
  local proj="$BATS_TEST_TMPDIR/lists/project.txt"
  printf '%s\n' zzqprojonly > "$proj"
  PG_EXTRA="[project.alpha.paths]"$'\n'"denylist_path = \"$proj\"" pg_config
  # the project list's name is not scanned for; the user-level list's is.
  _text 'this mentions zzqprojonly'
  pg_names
  pg_passes names
  _text "this mentions $PG_SENTINEL"
  pg_names
  pg_holds names names-hit hits=1 lines=1
  # with no user-level key the DEFAULT path is read, not the project's: the
  # canary on line 1 of a fixture post shows which list was scanned.
  rm "$PG_RECORDED"
  PG_PATHS=none PG_EXTRA="[project.alpha.paths]"$'\n'"denylist_path = \"$proj\"" pg_config
  pg_post
  echo 'and zzqprojonly' >> "$POST"
  pg_names
  pg_holds names names-hit hits=1 lines=1
}

@test "record: the first run records the path and writes one notify line naming the issue; the second writes none" {
  pg_post
  [ ! -e "$PG_RECORDED" ]
  [ "$(pg_notify_count)" = 0 ]
  pg_names
  pg_passes names
  [ "$(cat "$PG_RECORDED")" = "$(pg_resolved "$PG_LIST")" ]
  [ "$(grep -c '' "$PG_RECORDED")" -eq 1 ]
  [ "$(pg_notify_count)" = 1 ]
  [ "$(pg_probe field "$PG_NOTIFY" 1 event)" = notify ]
  [ "$(pg_probe field "$PG_NOTIFY" 1 project)" = alpha ]
  [ "$(pg_probe field "$PG_NOTIFY" 1 issue)" = Issue-7 ]
  [ "$(pg_probe type "$PG_NOTIFY" 1 capture)" = absent ]
  [ "$(pg_probe type "$PG_NOTIFY" 1 step)" = null ]
  [ "$(pg_probe type "$PG_NOTIFY" 1 question)" = null ]
  [ "$(pg_probe field "$PG_NOTIFY" 1 detail)" = "denylist path recorded" ]
  # the second run, and a held run, write nothing more.
  pg_names
  pg_passes names
  _text "has $PG_SENTINEL"
  pg_names
  pg_holds names names-hit hits=1 lines=1
  [ "$(pg_notify_count)" = 1 ]
  [ "$(cat "$PG_RECORDED")" = "$(pg_resolved "$PG_LIST")" ]
  # a capture's first run names the capture instead.
  rm "$PG_RECORDED"
  pg_post
  pg_run "$PG" check names --project alpha --capture 2026-11-24-some-slug --file "$POST"
  pg_passes names
  [ "$(pg_notify_count)" = 2 ]
  [ "$(pg_probe field "$PG_NOTIFY" 2 capture)" = 2026-11-24-some-slug ]
  [ "$(pg_probe type "$PG_NOTIFY" 2 issue)" = absent ]
}

@test "record: when the notify line cannot be written nothing is recorded and the check holds gate-error" {
  pg_post
  # A directory where the notifications file belongs: notify_check passes (it
  # opens nothing) and the append fails. On Git Bash the helper retries the
  # open until its lock deadline, so this row takes about 10 s there.
  mkdir "$PG_NOTIFY"
  pg_names
  pg_holds names gate-error notify-failed
  [ ! -e "$PG_RECORDED" ]
  [ -z "$(ls -A "$PG_NOTIFY")" ]
  # no temp file is left beside the record.
  [ -z "$(cd "$DA_HOME/state" && ls -A | grep '^post-gate-denylist-path' || true)" ]
  # once the file can be written the next run records.
  rmdir "$PG_NOTIFY"
  pg_names
  pg_passes names
  [ -f "$PG_RECORDED" ]
  [ "$(pg_notify_count)" = 1 ]
}

@test "record-denylist: afterwards a moved path passes; in a session marked unattended it exits 1 and records nothing" {
  pg_post
  local other="$BATS_TEST_TMPDIR/lists/other.txt" before
  pg_names
  pg_passes names
  printf '%s\n' "$PG_SENTINEL" > "$other"
  PG_PATHS="denylist_path = \"$other\"" pg_config
  pg_names
  pg_holds names denylist-moved
  before="$(_state_listing)"
  DEVAGENT_UNATTENDED=1 _record
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "post-gate: record-denylist refused unattended" ]
  [ "$(_state_listing)" = "$before" ]
  [ "$(cat "$PG_RECORDED")" = "$(pg_resolved "$PG_LIST")" ]
  # not marked unattended: it records and writes the same audit line.
  _record
  [ "$status" -eq 0 ]
  [ -z "$(pg_gate_lines)" ]
  [ "$(cat "$PG_RECORDED")" = "$(pg_resolved "$other")" ]
  [ "$(pg_notify_count)" = 2 ]
  [ "$(pg_probe field "$PG_NOTIFY" 2 detail)" = "denylist path recorded" ]
  [ "$(pg_probe field "$PG_NOTIFY" 2 issue)" = Issue-7 ]
  pg_names
  pg_passes names
  [ "$(pg_notify_count)" = 2 ]
  # a record that is not one line holds every run until it is re-recorded:
  # record-denylist replaces the record whatever it holds.
  printf 'two\nlines\n' > "$PG_RECORDED"
  pg_names
  pg_holds names gate-error record-malformed
  _record
  [ "$status" -eq 0 ]
  [ "$(cat "$PG_RECORDED")" = "$(pg_resolved "$other")" ]
  pg_names
  pg_passes names
  : > "$PG_RECORDED"
  _record
  [ "$status" -eq 0 ]
  pg_names
  pg_passes names
  # a directory where the record belongs cannot be replaced: gate-error, and
  # no audit line for a record that was never written.
  rm "$PG_RECORDED"; mkdir "$PG_RECORDED"
  before="$(pg_notify_count)"
  _record
  pg_holds names gate-error record-failed
  [ "$(pg_notify_count)" = "$before" ]
  [ -z "$(ls -A "$PG_RECORDED")" ]
}

@test "record-denylist: --expect of another path exits 1 and records nothing; a missing, unreadable or empty list holds gate-error" {
  pg_post
  local other="$BATS_TEST_TMPDIR/lists/other.txt" before
  printf '%s\n' zzqother > "$other"
  before="$(_state_listing)"
  _record --expect "$other"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "post-gate: record-denylist refused expect-mismatch" ]
  [ "$(_state_listing)" = "$before" ]
  # a path that does not exist, and one whose directory does not, are mismatches.
  _record --expect "$BATS_TEST_TMPDIR/lists/gone.txt"
  [ "$status" -eq 1 ]
  [ "$stderr" = "post-gate: record-denylist refused expect-mismatch" ]
  _record --expect "$BATS_TEST_TMPDIR/no-such-dir/denylist.txt"
  [ "$status" -eq 1 ]
  [ "$stderr" = "post-gate: record-denylist refused expect-mismatch" ]
  [ ! -e "$PG_RECORDED" ]
  # the expected path, in a second spelling: it goes through the resolver.
  _record --expect "$BATS_TEST_TMPDIR/lists/./denylist.txt"
  [ "$status" -eq 0 ]
  [ "$(cat "$PG_RECORDED")" = "$(pg_resolved "$PG_LIST")" ]
  [ "$(pg_notify_count)" = 1 ]
  # a list that is missing, is a directory, or has no entry is never recorded.
  rm "$PG_RECORDED"
  mv "$PG_LIST" "$PG_LIST.away"
  _record
  pg_holds names gate-error list-missing
  mkdir "$PG_LIST"
  _record
  pg_holds names gate-error list-missing
  rmdir "$PG_LIST"
  _list '# nothing here' ''
  _record
  pg_holds names gate-error list-empty
  [ ! -e "$PG_RECORDED" ]
  [ "$(pg_notify_count)" = 1 ]
  # a config fault is a gate-error too.
  PG_PATHS='denylist_path = "relative.txt"' pg_config
  _record
  pg_holds names gate-error path-not-absolute
  [ ! -e "$PG_RECORDED" ]
}

@test "denylist-status: prints each of the six states and never records" {
  pg_post
  local other="$BATS_TEST_TMPDIR/lists/other.txt" before
  # _is <token>: denylist-status prints <token>, exits 0 and writes nothing.
  _is() {
    before="$(_state_listing)"
    _status
    [ "$status" -eq 0 ] || { echo "rc=$status: $stderr" >&2; return 1; }
    [ "$output" = "$1" ] || { echo "want $1, got '$output'" >&2; return 1; }
    [ -z "$stderr" ] || { echo "stderr: $stderr" >&2; return 1; }
    [ "$(_state_listing)" = "$before" ] || { echo "the state directory changed" >&2; return 1; }
  }
  _is unrecorded
  [ ! -e "$PG_RECORDED" ]
  pg_names; pg_passes names
  _is present
  mv "$PG_LIST" "$PG_LIST.away"
  _is missing
  rm "$PG_RECORDED"
  _is absent
  mv "$PG_LIST.away" "$PG_LIST"
  _list '# comments only' '' '# public: zzqpub1'
  _is empty
  _list alpha beta                        # every entry is a configured project
  _is empty
  _list "$PG_SENTINEL"
  printf '%s\n' "$PG_SENTINEL" > "$other"
  pg_resolved "$other" > "$PG_RECORDED"
  _is moved
  # moved before missing, as the check orders them.
  rm "$PG_LIST"
  _is moved
  # row 1 cannot be told: exit 1, nothing on stdout.
  _list "$PG_SENTINEL"
  printf 'two\nlines\n' > "$PG_RECORDED"
  before="$(_state_listing)"
  _status
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$(_state_listing)" = "$before" ]
  rm "$PG_RECORDED"
  printf '[paths\n' > "$DA_HOME/config.toml"
  before="$(_state_listing)"
  _status
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ ! -e "$PG_RECORDED" ]
  [ "$(_state_listing)" = "$before" ]
  # the one audit line is the gate run's above; no status call added one.
  [ "$(pg_notify_count)" = 1 ]
}

@test "names --no-record: a fresh home reports the hit and records nothing" {
  local before
  before="$(_state_listing)"
  _text "has $PG_SENTINEL"
  pg_names --no-record
  pg_holds names names-hit hits=1 lines=1
  pg_post
  pg_names --no-record
  pg_passes names
  [ ! -e "$PG_RECORDED" ]
  [ ! -e "$PG_NOTIFY" ]
  [ "$(_state_listing)" = "$before" ]
  # control: without the flag the same clean run records.
  pg_names
  pg_passes names
  [ -f "$PG_RECORDED" ]
}

@test "names: text or a list that is not valid UTF-8 holds gate-error" {
  # an incomplete lead byte at a line end
  printf 'clean line\ncaf\xc3\nlast\n' > "$POST"
  pg_names
  pg_holds names gate-error invalid-utf8
  [ ! -e "$PG_RECORDED" ]
  pg_post
  printf '%s\nzzq\xc3\n' "$PG_SENTINEL" > "$PG_LIST"
  pg_names
  pg_holds names gate-error invalid-utf8
  [ ! -e "$PG_RECORDED" ]
  # control: the completed character is valid.
  printf '%s\nzzq\xc3\xa9\n' "$PG_SENTINEL" > "$PG_LIST"
  printf 'clean line\ncaf\xc3\xa9\nlast\n' > "$POST"
  pg_names
  pg_passes names
}

@test "names: a post that cannot be read holds gate-error" {
  rm -f "$POST"
  pg_names
  pg_holds names gate-error file-unreadable
  mkdir "$POST"
  pg_names
  pg_holds names gate-error file-unreadable
  [ ! -e "$PG_RECORDED" ]
}

@test "names: a verdict that disagrees with the line finder holds gate-error" {
  # The verdict is the shared predicate; the gate finds the lines itself. A
  # predicate that says "clean" over a post that has the sentinel …
  _text "has $PG_SENTINEL"
  pg_run bash -c '. "$1"; shift; potholes_private_name_hits() { return 0; }; post_gate_check names "$@"' _ "$PG" "${PG_COMMON[@]}" --no-record
  pg_holds names gate-error scan-disagree
  # … one that says "hit" over a clean post …
  pg_post
  pg_run bash -c '. "$1"; shift; potholes_private_name_hits() { return 1; }; post_gate_check names "$@"' _ "$PG" "${PG_COMMON[@]}" --no-record
  pg_holds names gate-error scan-disagree
  # … and one that cannot run.
  pg_run bash -c '. "$1"; shift; potholes_private_name_hits() { return 2; }; post_gate_check names "$@"' _ "$PG" "${PG_COMMON[@]}" --no-record
  pg_holds names gate-error scan-failed
}

@test "record: a second spelling of the same path is not moved" {
  pg_post
  pg_names
  pg_passes names
  local recorded dir="$BATS_TEST_TMPDIR/lists"
  recorded="$(cat "$PG_RECORDED")"
  # _spelled <path>: the config names the list as <path>; the run still passes
  # and the record is untouched.
  _spelled() {
    PG_PATHS="denylist_path = \"$1\"" pg_config
    pg_names
    pg_passes names || { echo "spelling: $1" >&2; return 1; }
    [ "$(cat "$PG_RECORDED")" = "$recorded" ]
  }
  _spelled "$dir/./denylist.txt"
  _spelled "$BATS_TEST_TMPDIR/home/../lists/denylist.txt"
  _spelled "~/../lists/denylist.txt"                       # ~ is $HOME, a sibling of lists/
  if is_git_bash; then
    _spelled "$(cygpath -m "$PG_LIST")"                    # C:/…
    _spelled "$(cygpath -u "$PG_LIST")"                    # /c/…
    _spelled "$dir/DENYLIST.txt"                           # re-cased: one file by -ef
    _spelled "$(cygpath -m "$dir" | tr '[:lower:]' '[:upper:]')/denylist.txt"
  else
    ln -s "$dir" "$BATS_TEST_TMPDIR/lists-link"
    _spelled "$BATS_TEST_TMPDIR/lists-link/denylist.txt"   # through a symlinked directory
  fi
  [ "$(pg_notify_count)" = 1 ]
  # control: another file under the first spelling's name is a move.
  printf '%s\n' "$PG_SENTINEL" > "$dir/other.txt"
  PG_PATHS="denylist_path = \"$dir/./other.txt\"" pg_config
  pg_names
  pg_holds names denylist-moved
}
