#!/usr/bin/env bash
# scripts/lib/io.sh — small io helpers. Safe to source multiple times.

_io_progname() {
  # #320: name the ENTRY script ($0), not BASH_SOURCE[1] — which from inside
  # die/warn/info is io.sh's own frame, so every diagnostic was prefixed "io.sh:".
  basename "$0"
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

# date_tag — YYYY-MM-DD, honoring DEVAGENT_DATE_OVERRIDE for test determinism
# (#338). Mirrors capture/lib/slug.sh so the analyze family and the capture
# family agree. Falls back to the real date when the override is unset.
date_tag() {
  if [[ -n "${DEVAGENT_DATE_OVERRIDE:-}" ]]; then
    printf '%s\n' "$DEVAGENT_DATE_OVERRIDE"
  else
    date +%Y-%m-%d
  fi
}
