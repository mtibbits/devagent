#!/usr/bin/env bash
# scripts/capture/lib/slug.sh — slug generation for captures.
# Sourced; defines functions only.
# shellcheck shell=bash

devagent_today() {
  if [[ -n "${DEVAGENT_DATE_OVERRIDE:-}" ]]; then
    printf '%s\n' "${DEVAGENT_DATE_OVERRIDE}"
  else
    date +%Y-%m-%d
  fi
}

devagent_slug() {
  local title="${1:-}"
  if [[ -z "${title}" ]]; then
    echo "devagent_slug: empty title" >&2
    return 2
  fi
  local kebab
  kebab="$(printf '%s' "${title}" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  if [[ -z "${kebab}" ]]; then
    echo "devagent_slug: title sanitizes to empty" >&2
    return 2
  fi
  if [[ "${#kebab}" -gt 60 ]]; then
    kebab="${kebab:0:60}"
    kebab="${kebab%-}"
  fi
  printf '%s-%s\n' "$(devagent_today)" "${kebab}"
}
