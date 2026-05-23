#!/usr/bin/env bash
# Stub for scripts/lib/state.sh (Plan 2). Minimal flat TOML reader/writer
# supporting only `key = "value"` lines (no sections, no arrays).

state_get() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || { printf ''; return 0; }
  awk -v k="$key" '
    $1 == k && $2 == "=" {
      sub(/^[^=]*=[[:space:]]*/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }' "$file"
}

state_set() {
  local file="$1" key="$2" value="$3"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  if grep -q "^${key} *= *" "$file"; then
    local tmp; tmp="$(mktemp)"
    awk -v k="$key" -v v="$value" '
      $1 == k && $2 == "=" { printf "%s = \"%s\"\n", k, v; next }
      { print }' "$file" > "$tmp"
    mv "$tmp" "$file"
  else
    printf '%s = "%s"\n' "$key" "$value" >> "$file"
  fi
}
export -f state_get state_set
