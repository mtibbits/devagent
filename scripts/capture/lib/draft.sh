#!/usr/bin/env bash
# scripts/capture/lib/draft.sh — reading a capture draft.
# Sourced; defines functions only.
# shellcheck shell=bash

# #597: the draft's tracker title — its first "# " line, prefix stripped.
# The ONE spelling of it: file.sh files this string and capture.sh gates
# --body-file on it, so the gate and the filer cannot drift (Issue-585).
devagent_draft_h1() {
  awk '/^# /{sub(/^# */,""); print; exit}' "${1:?}"
}
