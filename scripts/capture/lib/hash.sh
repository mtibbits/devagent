#!/usr/bin/env bash
# scripts/capture/lib/hash.sh — content hashing for reap idempotence.
# Sourced; defines functions only.
# shellcheck shell=bash

# Normalize text before hashing so cosmetic variations don't bypass
# the dedupe: lowercase, collapse runs of whitespace to single space,
# trim leading/trailing whitespace.
devagent_hash_text() {
  local input="${1:-}"
  printf '%s' "${input}" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -s '[:space:]' ' ' \
    | sed -E 's/^ //; s/ $//' \
    | sha256sum \
    | awk '{print substr($1, 1, 12)}'
}
