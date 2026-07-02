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

# posix_modes_representable <dir> — true when the filesystem under <dir>
# honors chmod. On Windows/NTFS (MSYS/Cygwin "noacl" mounts) chmod is a
# no-op and every mode reads back 755/644, so 700/600 invariants can never
# hold; mode checks are meaningless there (the NTFS ACL on the user profile
# is the effective protection) and callers skip them. Fail-safe by
# direction: EVERY uncertainty (can't create a probe, chmod fails, stat
# fails) returns true so a real audit still runs — only a probe that was
# created and chmod'd yet reads back != 600 declares modes unrepresentable.
# Uses mktemp (not a predictable $$ name): a pre-planted file/symlink at a
# guessable path in a world-writable secrets dir could otherwise suppress
# the very audit that would flag it, or redirect the chmod (TOCTOU).
posix_modes_representable() {
  local dir="$1" probe mode rc
  probe="$(mktemp "$dir/.mode-probe.XXXXXX" 2>/dev/null)" || return 0
  if ! chmod 600 "$probe" 2>/dev/null; then rm -f "$probe"; return 0; fi
  mode="$(stat -c '%a' "$probe" 2>/dev/null)"; rc=$?
  rm -f "$probe"
  [ "$rc" -eq 0 ] || return 0
  [ "$mode" = "600" ]
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
