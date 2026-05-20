#!/usr/bin/env bash
# scripts/lib/io.sh — small io helpers. Safe to source multiple times.

_io_progname() {
  basename "${BASH_SOURCE[1]:-${0}}"
}

die() {
  echo "$(_io_progname): $*" >&2
  exit 1
}

info() {
  echo "$(_io_progname): $*" >&2
}

warn() {
  echo "$(_io_progname): WARNING: $*" >&2
}

is_tty() {
  [[ -t 0 ]]
}

confirm() {
  local prompt="${1:-Proceed?}"
  if [[ "${DA_YES:-}" == "1" ]]; then
    return 0
  fi
  if ! is_tty; then
    return 1
  fi
  local reply
  read -r -p "$prompt [Y/n] " reply
  case "$reply" in
    ""|y|Y|yes|YES) return 0 ;;
    *)              return 1 ;;
  esac
}
