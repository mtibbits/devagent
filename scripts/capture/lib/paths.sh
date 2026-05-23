#!/usr/bin/env bash
# scripts/capture/lib/paths.sh — capture path resolution.
# Sourced; defines functions only.
# shellcheck shell=bash

devagent_captures_root() {
  if [[ -z "${DEVAGENT_DEVDOC_DIR:-}" ]]; then
    echo "DEVAGENT_DEVDOC_DIR not set" >&2
    return 2
  fi
  printf '%s/Captures\n' "${DEVAGENT_DEVDOC_DIR%/}"
}

devagent_validate_slug() {
  local slug="${1:-}"
  if [[ -z "${slug}" ]]; then
    echo "invalid slug: empty" >&2
    return 2
  fi
  case "${slug}" in
    .*|*/*|*$'\n'*) echo "invalid slug: ${slug}" >&2; return 2 ;;
  esac
}

devagent_capture_dir() {
  local slug="${1:-}"
  devagent_validate_slug "${slug}" || return $?
  local root
  root="$(devagent_captures_root)" || return $?
  printf '%s/%s\n' "${root}" "${slug}"
}

devagent_ensure_capture_dir() {
  local slug="${1:-}"
  local dir
  dir="$(devagent_capture_dir "${slug}")" || return $?
  mkdir -p "${dir}"
  printf '%s\n' "${dir}"
}
