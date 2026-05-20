#!/usr/bin/env bash
# scripts/lib/secrets.sh — bootstrap and audit the secrets directory.
# Requires paths.sh and io.sh sourced first.

secrets_bootstrap() {
  local dir
  dir="$(secrets_dir)"
  mkdir -p "$dir"
  chmod 700 "$dir"
}

secrets_audit() {
  local dir mode f ok=1
  dir="$(secrets_dir)"
  if [[ ! -d "$dir" ]]; then
    warn "secrets dir missing: $dir (run secrets_bootstrap)"
    return 1
  fi
  mode="$(stat -c '%a' "$dir")"
  if [[ "$mode" != "700" ]]; then
    warn "secrets dir mode is $mode, expected 700: $dir"
    ok=0
  fi
  shopt -s nullglob
  for f in "$dir"/*; do
    [[ -L "$f" ]] && continue
    [[ -f "$f" ]] || continue
    mode="$(stat -c '%a' "$f")"
    if [[ "$mode" != "600" ]]; then
      warn "secret file mode is $mode, expected 600: $f"
      ok=0
    fi
  done
  shopt -u nullglob
  [[ "$ok" == "1" ]]
}
