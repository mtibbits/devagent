#!/usr/bin/env bash
# scripts/lib/secrets.sh
#
# Storage abstraction for devAgent secrets, plus the original Plan 1
# bootstrap/audit helpers.
#
# Storage API (Plan 8):
#   secret_backend                 — prints active backend ("file" in v1)
#   secret_path     PROJ BACKEND   — canonical PAT path
#   secret_write    PROJ BACKEND V — write value V (atomic, mode 600, dir 700)
#   secret_read     PROJ BACKEND   — print value or exit 2 if absent
#   secret_destroy  PROJ BACKEND   — shred -u then unlink; idempotent
#   secret_stat     PROJ BACKEND   — print metadata; never the value
#
# Audit API (Plan 1):
#   secrets_bootstrap              — mkdir + chmod 700 on the secrets dir
#   secrets_audit                  — verify dir 700 and file 600 invariants
#
# Mode API:
#   posix_modes_representable DIR  — can a file under DIR carry mode 600? (#289)
#   suite_mode_reference PATH...   — does suite source reference a file mode? (#600)
#
# Environment:
#   DEVAGENT_ROOT             (default ~/.claude/devagent)
#   DEVAGENT_SECRETS_DIR      (default $DEVAGENT_ROOT/secrets)
#   DEVAGENT_SECRETS_BACKEND  (default "file"; "keyring" reserved for v2)

: "${DEVAGENT_ROOT:=${HOME}/.claude/devagent}"
: "${DEVAGENT_SECRETS_DIR:=${DEVAGENT_ROOT}/secrets}"
: "${DEVAGENT_SECRETS_BACKEND:=file}"

secret_backend() {
  printf '%s\n' "${DEVAGENT_SECRETS_BACKEND}"
}

_secret_validate_name() {
  local kind="$1" val="$2"
  if [ -z "${val}" ]; then
    echo "secrets: ${kind} must be non-empty" >&2
    return 1
  fi
  case "${val}" in
    *[/\\\ \"\'\`\$\;\|]* )
      echo "secrets: ${kind} contains forbidden characters: ${val}" >&2
      return 1
      ;;
    .|..)
      echo "secrets: ${kind} must not be '.' or '..'" >&2
      return 1
      ;;
  esac
  return 0
}

_secret_require_file_backend() {
  if [ "${DEVAGENT_SECRETS_BACKEND}" != "file" ]; then
    echo "secrets: keyring backend not implemented in v1 (set DEVAGENT_SECRETS_BACKEND=file)" >&2
    return 1
  fi
}

_secret_ensure_dir() {
  if [ ! -d "${DEVAGENT_SECRETS_DIR}" ]; then
    install -d -m 0700 "${DEVAGENT_SECRETS_DIR}"
  else
    chmod 0700 "${DEVAGENT_SECRETS_DIR}"
  fi
}

secret_path() {
  local proj="$1" backend="$2"
  _secret_validate_name project "${proj}" || return 1
  _secret_validate_name backend "${backend}" || return 1
  printf '%s/%s.%s.pat\n' "${DEVAGENT_SECRETS_DIR}" "${proj}" "${backend}"
}

secret_write() {
  local proj="$1" backend="$2" value="$3"
  _secret_validate_name project "${proj}" || return 1
  _secret_validate_name backend "${backend}" || return 1
  _secret_require_file_backend || return 1
  if [ -z "${value}" ]; then
    echo "secrets: refusing to write empty value" >&2
    return 1
  fi
  _secret_ensure_dir
  local dest tmp
  dest="$(secret_path "${proj}" "${backend}")"
  tmp="$(mktemp "${DEVAGENT_SECRETS_DIR}/.tmp.XXXXXX")"
  chmod 0600 "${tmp}"
  printf '%s' "${value}" >"${tmp}"
  mv -f "${tmp}" "${dest}"
  chmod 0600 "${dest}"
}

secret_read() {
  local proj="$1" backend="$2"
  _secret_validate_name project "${proj}" || return 1
  _secret_validate_name backend "${backend}" || return 1
  _secret_require_file_backend || return 1
  local f
  f="$(secret_path "${proj}" "${backend}")"
  if [ ! -f "${f}" ]; then
    return 2
  fi
  cat "${f}"
}

secret_destroy() {
  local proj="$1" backend="$2"
  _secret_validate_name project "${proj}" || return 1
  _secret_validate_name backend "${backend}" || return 1
  _secret_require_file_backend || return 1
  local f
  f="$(secret_path "${proj}" "${backend}")"
  if [ ! -e "${f}" ]; then
    return 0
  fi
  if command -v shred >/dev/null 2>&1; then
    shred -u -- "${f}"
  else
    local sz
    sz="$(stat -c '%s' "${f}" 2>/dev/null || echo 0)"
    dd if=/dev/zero of="${f}" bs=1 count="${sz}" conv=notrunc status=none 2>/dev/null || true
    rm -f -- "${f}"
  fi
}

secret_stat() {
  local proj="$1" backend="$2"
  _secret_validate_name project "${proj}" || return 1
  _secret_validate_name backend "${backend}" || return 1
  _secret_require_file_backend || return 1
  local f
  f="$(secret_path "${proj}" "${backend}")"
  if [ ! -f "${f}" ]; then
    printf 'project=%s backend=%s present=false\n' "${proj}" "${backend}"
    return 0
  fi
  local size mtime mode
  size="$(stat -c '%s' "${f}")"
  mtime="$(stat -c '%y' "${f}")"
  mode="$(stat -c '%a' "${f}")"
  printf 'project=%s backend=%s present=true mode=%s size_bytes=%s mtime=%s\n' \
    "${proj}" "${backend}" "${mode}" "${size}" "${mtime}"
}

# ---------------------------------------------------------------------------
# Plan 1 audit helpers (kept for backwards compatibility with /devagent:doctor
# and older callers). secrets_dir() comes from scripts/lib/paths.sh; warn()
# from scripts/lib/io.sh — these are sourced before us in the Plan 1 wiring.
# ---------------------------------------------------------------------------

secrets_bootstrap() {
  local dir
  if command -v secrets_dir >/dev/null 2>&1; then
    dir="$(secrets_dir)"
  else
    dir="${DEVAGENT_SECRETS_DIR}"
  fi
  mkdir -p "$dir"
  chmod 700 "$dir"
}

# posix_modes_representable <dir> — true when a file under <dir> can carry a
# distinct POSIX mode (specifically, reads back as 600). On "noacl" mounts
# (MSYS/Cygwin NTFS, vfat/exfat) chmod is a no-op and every mode reads back
# 755/644, so 700/600 invariants can never hold; mode checks are meaningless
# there (filesystem/OS access control governs instead) and callers skip them.
# Fail-safe by
# direction: EVERY uncertainty (can't create a probe, chmod fails, stat
# fails) returns true so a real audit still runs — only a probe that was
# created and chmod'd yet reads back != 600 declares modes unrepresentable.
# Uses mktemp (not a predictable $$ name): a pre-planted file/symlink at a
# guessable path in a world-writable secrets dir could otherwise suppress
# the very audit that would flag it, or redirect the chmod (TOCTOU).
posix_modes_representable() {
  local dir="$1" probe mode
  probe="$(mktemp "$dir/.mode-probe.XXXXXX" 2>/dev/null)" || return 0
  # Each failure is handled with an explicit `if !` (not `cmd; rc=$?`) so the
  # fail-safe holds even if a future caller invokes this bare under `set -e`
  # (today every call site is an `if !` condition, which already suppresses
  # errexit — but the guarantee must not depend on that).
  if ! chmod 600 "$probe" 2>/dev/null; then rm -f "$probe"; return 0; fi
  if ! mode="$(stat -c '%a' "$probe" 2>/dev/null)"; then rm -f "$probe"; return 0; fi
  rm -f "$probe"
  [ "$mode" = "600" ]
}

# suite_mode_reference <path>... — does the suite source under <path>... REFERENCE a
# file mode (#600)? The #565 run-suite gate asks this only where chmod is a no-op, to
# tell a suite that could be asserting modes (refuse) from one that cannot (proceed and
# say so in the artifact). A PROXY, and the artifact says so. It sees tokens that SET or
# READ a mode in the scanned files; it does NOT see a mode dependency that lives only in
# the code under test, test-support code loaded from OUTSIDE the scanned paths (a bats
# `load '../lib/x'`, a pytest plugin elsewhere), a `[ -x` / `-w` test operator,
# `find -perm`, or the target of a symlink that a `core.symlinks=false` checkout
# materialised as a text file. Tokens are
# word-bounded with a portable ERE class rather than `\b`: unbounded, `st_mode` matched
# inside `test_mode_split` and `permission` matched licence prose (#600 draft measurement
# over three real pure-pytest suites). `chmod +x` on a stub and a bare `ls -l` count as
# references: over-firing is the fail-closed direction.
# Universe: the WORKING TREE under each <path>, recursively, following symlinks (`-R`; a
# symlink loop is a grep error, so rc 2) — what bats and pytest actually execute,
# untracked files included, which is why this is not a tracked-only `git grep`.
# rc 0 = found (SUITE_MODE_HIT = lexically-first `file:line:text`, SUITE_MODE_COUNT =
# hit lines), 1 = none, 2 = could not determine — callers must fail CLOSED on 2
# (register Issue-243); on 2, SUITE_MODE_ERR carries grep's first error line (a
# dangling symlink under -R is the routine cause) so the refusal names what failed.
# A positive control runs first through the same grep and ERE: a dialect that silently
# matches NOTHING would otherwise report every suite clean. It does not detect a grep
# that drops only SOME alternatives — the per-alternative rows in
# tests/suite-fs-preflight.bats pin those for the grep the suite runs under.
# Setter-globals: call bare (`… || rc=$?`), never inside $( … ) (register Issue-282).
SUITE_MODE_TOKEN_RE='(^|[^[:alnum:]_])(chmod|fchmod|lchmod|umask|st_mode|S_IMODE|S_I[RWX](USR|GRP|OTH)|S_IRWX[UGO]|os\.access|[RWX]_OK|PermissionError|EACCES|copymode|filemode|stat( +-[A-Za-z]+)* +(-c|-f|--format|--printf)|stat +-[A-Za-z]*[cf]|ls( +-[A-Za-z]+)* +-[A-Za-z]*l[A-Za-z]*|(mkdir|install)( +-[A-Za-z]+)* +(-[A-Za-z]*m[0-7]*|--mode)|0o[0-7]{3,4})([^[:alnum:]_]|$)'
# shellcheck disable=SC2034  # SUITE_MODE_HIT/COUNT/ERR are consumed by callers (run-suite.sh), not here
suite_mode_reference() {
  local hits rc=0 errf
  SUITE_MODE_HIT=""; SUITE_MODE_COUNT=0; SUITE_MODE_ERR=""
  if ! grep -qE -- "$SUITE_MODE_TOKEN_RE" <<<'chmod 600 x' 2>/dev/null; then
    SUITE_MODE_ERR="grep failed its positive control (no match for 'chmod 600 x')"
    return 2
  fi
  errf="$(mktemp "${TMPDIR:-/tmp}/suite-mode-err.XXXXXX")" \
    || { SUITE_MODE_ERR="mktemp failed"; return 2; }
  hits="$(grep -RnIE -- "$SUITE_MODE_TOKEN_RE" "$@" 2>"$errf")" || rc=$?
  IFS= read -r SUITE_MODE_ERR <"$errf" || true
  rm -f "$errf"
  case "$rc" in
    0) # Sorted so "first" does not depend on readdir order (NTFS vs ext4); line
       # numbers numerically, so :10: does not precede :2:.
       hits="$(LC_ALL=C sort -t: -k1,1 -k2,2n <<<"$hits")" || return 2
       SUITE_MODE_HIT="${hits%%$'\n'*}"
       local -a lines; mapfile -t lines <<<"$hits"; SUITE_MODE_COUNT=${#lines[@]}
       return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

secrets_audit() {
  local dir mode f ok=1
  if command -v secrets_dir >/dev/null 2>&1; then
    dir="$(secrets_dir)"
  else
    dir="${DEVAGENT_SECRETS_DIR}"
  fi
  if [[ ! -d "$dir" ]]; then
    if command -v warn >/dev/null 2>&1; then
      warn "secrets dir missing: $dir (run secrets_bootstrap)"
    else
      echo "secrets dir missing: $dir (run secrets_bootstrap)" >&2
    fi
    return 1
  fi
  if ! posix_modes_representable "$dir"; then
    if command -v warn >/dev/null 2>&1; then
      warn "filesystem does not represent POSIX modes; skipping 700/600 audit: $dir"
    else
      echo "filesystem does not represent POSIX modes; skipping 700/600 audit: $dir" >&2
    fi
    return 0
  fi
  mode="$(stat -c '%a' "$dir")"
  if [[ "$mode" != "700" ]]; then
    if command -v warn >/dev/null 2>&1; then
      warn "secrets dir mode is $mode, expected 700: $dir"
    else
      echo "secrets dir mode is $mode, expected 700: $dir" >&2
    fi
    ok=0
  fi
  shopt -s nullglob
  for f in "$dir"/*; do
    [[ -L "$f" ]] && continue
    [[ -f "$f" ]] || continue
    mode="$(stat -c '%a' "$f")"
    if [[ "$mode" != "600" ]]; then
      if command -v warn >/dev/null 2>&1; then
        warn "secret file mode is $mode, expected 600: $f"
      else
        echo "secret file mode is $mode, expected 600: $f" >&2
      fi
      ok=0
    fi
  done
  shopt -u nullglob
  [[ "$ok" == "1" ]]
}
