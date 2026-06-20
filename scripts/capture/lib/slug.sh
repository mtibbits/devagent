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
  # #252: optional disambiguating suffix (e.g. the reap collision body-hash). It
  # is appended AFTER the 60-char cap with room reserved, so — unlike appending
  # it to the title — it always survives truncation. Empty/absent ⇒ behavior is
  # byte-identical to the pre-#252 single-cap path.
  local suffix="${2:-}"
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
  local ksuf=""
  if [[ -n "${suffix}" ]]; then
    ksuf="$(printf '%s' "${suffix}" \
      | tr '[:upper:]' '[:lower:]' \
      | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  fi
  if [[ -n "${ksuf}" ]]; then
    # Reserve room for "-<ksuf>" within the 60-char cap; clamp the title budget
    # to >=1 so a pathologically long suffix can't yield an empty/leading-dash
    # kebab. The suffix is then guaranteed present in the final slug.
    local budget=$(( 60 - ${#ksuf} - 1 ))
    (( budget < 1 )) && budget=1
    if [[ "${#kebab}" -gt "${budget}" ]]; then
      kebab="${kebab:0:${budget}}"
      kebab="${kebab%-}"
    fi
    kebab="${kebab}-${ksuf}"
  elif [[ "${#kebab}" -gt 60 ]]; then
    kebab="${kebab:0:60}"
    kebab="${kebab%-}"
  fi
  printf '%s-%s\n' "$(devagent_today)" "${kebab}"
}
