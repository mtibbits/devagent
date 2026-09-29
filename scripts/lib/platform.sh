#!/usr/bin/env bash
# scripts/lib/platform.sh - the #654 PLATFORM STAMP: where a suite-count artifact was
# produced, and which platforms the operator who RUNS preship accepts. ONE home for the
# grammar, read by the producer (run-suite.sh) and the checker (preship-evidence.sh), so the
# two cannot disagree about the shape (register Issue-565/232). Requires paths.sh, io.sh and
# config.sh sourced first.
#
# The line (fixed keys, in this order, single spaces):
#   platform: os=<uname -s> kernel=<uname -r> fs=<filesystem type of the measured tree> modes=posix|no-op
# - fs is `df --output=fstype` (GNU coreutils) of the measured tree: ext4 for the WSL clone,
#   9p for a WSL /mnt/c checkout, ntfs under Git Bash (measured, Issue-654 draft). It is the
#   discriminator a kernel string lacks. `stat -f -c %T` cannot serve: it names ext4
#   `ext2/ext3` and prints `UNKNOWN (0x...)` under Git Bash.
# - modes is the #565 chmod probe's answer (posix_modes_representable over the measured tree
#   and TMPDIR), passed in by the caller from the SAME run that renders file_modes:. `posix`
#   means "no no-op detected": that probe fails open where chmod errors or it cannot write
#   (secrets.sh), so `posix` is never proof that modes work.
# - A value is [A-Za-z0-9._+-]+. Any other byte a probe printed is recorded as `_`, under the
#   C locale so one platform always records one line; a probe that failed or printed nothing
#   records `(unknown)` (BSD df has no --output, so an untested macOS records fs=(unknown)).
#   The stamp never refuses and never stops a run.
# - Never a host name (no `uname -n`/`-a`, no `hostname`): the artifact is quoted into public
#   MR bodies. No override: no variable or config key sets, suppresses or edits the line.
# - The body shape is FROZEN (imPlan D11). A line that is not this shape fails preship,
#   declared or not, and mr.md's Evidence block copies it byte for byte. So adding a key or a
#   modes= value is a coordinated producer + checker + template change in one release.
# Stated blind spot: the line is a CLAIM the artifact makes. A hand-written artifact can carry
# any well-formed platform: line, and no checker can tell (the #655 tree: stamp's limit too).

_PLATFORM_V='[A-Za-z0-9._+-]+'
_PLATFORM_F="(${_PLATFORM_V}|\(unknown\))"
# The ONE permitted body shape (register fleet Issue-20: assert the one shape, never bad ones).
PLATFORM_BODY_RE="^os=$_PLATFORM_F kernel=$_PLATFORM_F fs=$_PLATFORM_F modes=(posix|no-op)\$"
# One declared pair: a stamp key and a CONCRETE value, so (unknown) is never declarable, and
# modes only posix or no-op.
PLATFORM_PAIR_RE="^((os|kernel|fs)=${_PLATFORM_V}|modes=(posix|no-op))\$"

# _platform_token <raw> - stdout: <raw> trimmed, each byte outside the value class as `_`, or
# `(unknown)` when nothing is left. Pure, so safe inside $( ... ).
_platform_token() {
  local LC_ALL=C
  local r="$1"
  r="${r#"${r%%[![:space:]]*}"}"
  r="${r%"${r##*[![:space:]]}"}"
  r="${r//[!A-Za-z0-9._+-]/_}"
  printf '%s' "${r:-(unknown)}"
}

# platform_stamp_resolve <dir> <modes> - SETTER-GLOBAL PLATFORM_BODY: call bare, never in
# $( ... ) (register Issue-282). <modes> is the caller's #565 probe answer.
# shellcheck disable=SC2034  # PLATFORM_BODY is the return channel - read by run-suite.sh (#654)
platform_stamp_resolve() {
  local dir="$1" modes="$2" os="" kernel="" df_out="" fs=""
  case "$modes" in
    posix|no-op) ;;
    *) die "platform_stamp_resolve: internal error - modes '$modes' is neither posix nor no-op (#654)" ;;
  esac
  os="$(uname -s 2>/dev/null)" || os=""
  kernel="$(uname -r 2>/dev/null)" || kernel=""
  df_out="$(df --output=fstype -- "$dir" 2>/dev/null)" || df_out=""
  # Line 2 is the value; line 1 is df's "Type" header, and a header alone is no answer.
  case "$df_out" in *$'\n'*) fs="${df_out#*$'\n'}"; fs="${fs%%$'\n'*}" ;; esac
  PLATFORM_BODY="os=$(_platform_token "$os") kernel=$(_platform_token "$kernel") fs=$(_platform_token "$fs") modes=$modes"
}

# platform_body_valid <body> - rc 0 iff <body> is the one shape above. C locale, so the class
# is ASCII on every host.
platform_body_valid() {
  local LC_ALL=C
  [[ "$1" =~ $PLATFORM_BODY_RE ]]
}

# platform_entry_valid <entry> - rc 0 iff <entry> is one or more PLATFORM_PAIR_RE pairs
# joined by single spaces (no leading, trailing, doubled or tab separator), each key at most
# once. IFS is pinned: the split and the re-join are on single spaces whatever the caller set.
platform_entry_valid() {
  local LC_ALL=C IFS=' '
  local e="$1" p k seen=" "
  local -a pairs=()
  read -r -a pairs <<<"$e"
  [ "${#pairs[@]}" -gt 0 ] || return 1
  [ "${pairs[*]}" = "$e" ] || return 1
  for p in "${pairs[@]}"; do
    [[ "$p" =~ $PLATFORM_PAIR_RE ]] || return 1
    k="${p%%=*}"
    case "$seen" in *" $k "*) return 1 ;; esac
    seen+="$k "
  done
}

# platform_entry_matches <entry> <body> - rc 0 iff every pair of <entry> is a WHOLE field of
# <body>: exact, so fs=ext does not match fs=ext4. An empty entry matches NOTHING, never
# everything (a zero-pair loop would otherwise pass vacuously).
platform_entry_matches() {
  local p IFS=' '
  local -a pairs=()
  read -r -a pairs <<<"$1"
  [ "${#pairs[@]}" -gt 0 ] || return 1
  for p in "${pairs[@]}"; do
    [[ " $2 " == *" $p "* ]] || return 1
  done
}

# platform_declaration_resolve <project> - the optional [project.<name>] evidence_platforms of
# THIS config, the CHECKING operator's. SETTER-GLOBALS, call bare (register Issue-282):
#   PLATFORM_DECLARED_SET   true | false (the key is absent: nothing is declared)
#   PLATFORM_DECLARED       ( entry ... ), in config order
# Dies before any check is decided (the suite_env/suite_jobs shape) on a value that is not an
# array of single-line strings, an empty array, or any entry platform_entry_valid refuses.
# shellcheck disable=SC2034  # the return channel - read by preship-evidence.sh (#654)
platform_declaration_resolve() {
  local project="$1" out="" rc=0 e cfg
  cfg="$(config_path)"
  PLATFORM_DECLARED=(); PLATFORM_DECLARED_SET=false
  # `&& printf .` is a sentinel: $( ... ) strips trailing newlines, which would silently drop an
  # empty LAST element (measured). The rc is get-list's own: 1 absent, 3 wrong type.
  out="$(config_get_project_list "$project" evidence_platforms 2>/dev/null && printf .)" || rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    3) die "evidence_platforms: [project.$project] evidence_platforms in $cfg must be an array of single-line strings, e.g. evidence_platforms = [\"os=Linux fs=ext4 modes=posix\"] (#654)" ;;
    *) die "evidence_platforms: could not read [project.$project] evidence_platforms from $cfg (exit $rc) (#654)" ;;
  esac
  out="${out%.}"
  [ -n "$out" ] \
    || die "evidence_platforms: [project.$project] evidence_platforms in $cfg is empty - list at least one platform, or remove the key to declare none (#654)"
  mapfile -t PLATFORM_DECLARED <<<"${out%$'\n'}"
  for e in "${PLATFORM_DECLARED[@]}"; do
    platform_entry_valid "$e" \
      || die "evidence_platforms: entry '$e' in [project.$project] evidence_platforms ($cfg) is not valid - an entry is one or more key=value pairs separated by single spaces: keys os, kernel, fs, modes, each at most once; values of letters, digits and . _ + -; modes only posix or no-op; e.g. \"os=Linux fs=ext4 modes=posix\" (#654)"
  done
  PLATFORM_DECLARED_SET=true
}
