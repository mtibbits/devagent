#!/usr/bin/env bats
#
# #92: tokens must never reach curl's argv (readable via /proc/<pid>/cmdline).
# bc_curl_auth / BC_AUTH_HEADER feed the auth header to curl via --config on
# stdin instead.

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  STUB_BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$STUB_BIN"
  ARGV_FILE="$BATS_TEST_TMPDIR/curl.argv"
  STDIN_FILE="$BATS_TEST_TMPDIR/curl.stdin"
  # Stub curl: append argv + stdin to files, write JSON to the -o target, and
  # print the http_code that bc_curl's -w expects.
  cat > "$STUB_BIN/curl" <<EOF
#!/usr/bin/env bash
printf 'ARGV: %s\n' "\$*" >> "$ARGV_FILE"
{ printf 'STDIN<<\n'; cat; printf '\n>>\n'; } >> "$STDIN_FILE"
out=""; prev=""
for a in "\$@"; do [ "\$prev" = "-o" ] && out="\$a"; prev="\$a"; done
[ -n "\$out" ] && printf '{}' > "\$out"
printf '200'
EOF
  chmod +x "$STUB_BIN/curl"
  export PATH="$STUB_BIN:$PATH"
  source "$PLUGIN_ROOT/scripts/lib/backend-common.sh"
}
teardown() { teardown_tmp_devagent_home; }

@test "bc_curl_auth keeps the token out of curl argv (#92)" {
  run bc_curl_auth "PRIVATE-TOKEN: glpat-SECRET123" GET https://x.example/api \
    -H "Accept: application/json"
  [ "$status" -eq 0 ]
  run cat "$ARGV_FILE"
  [[ "$output" != *"glpat-SECRET123"* ]]          # token NOT in argv
  [[ "$output" == *"--config"* ]]                 # used --config
  [[ "$output" == *"Accept: application/json"* ]] # non-secret header stays argv
  grep -q 'glpat-SECRET123' "$STDIN_FILE"         # token IS in the stdin config
  grep -q 'header = ' "$STDIN_FILE"
}

@test "bc_curl honors BC_AUTH_HEADER via stdin, not argv (#92)" {
  BC_AUTH_HEADER="PRIVATE-TOKEN: glpat-ENVSECRET" run bc_curl GET https://x.example/api
  [ "$status" -eq 0 ]
  run cat "$ARGV_FILE"
  [[ "$output" != *"glpat-ENVSECRET"* ]]
  [[ "$output" == *"--config"* ]]
  grep -q 'glpat-ENVSECRET' "$STDIN_FILE"
}

@test "bc_curl without BC_AUTH_HEADER does not add --config (#92)" {
  run bc_curl GET https://x.example/api
  [ "$status" -eq 0 ]
  run cat "$ARGV_FILE"
  [[ "$output" != *"--config"* ]]
}

@test "bc_curl_auth escapes quotes/backslashes in the config value (#92)" {
  run bc_curl_auth 'PRIVATE-TOKEN: ab"c\d' GET https://x.example/api
  [ "$status" -eq 0 ]
  # the raw token must not break out of the quoted config value
  grep -q 'header = "PRIVATE-TOKEN: ab\\"c\\\\d"' "$STDIN_FILE"
  run cat "$ARGV_FILE"
  [[ "$output" != *'ab"c'* ]]   # still never in argv
}

@test "gitlab issue backend never puts GITLAB_TOKEN in curl argv (#92)" {
  export GITLAB_TOKEN="glpat-INTEGRATION-SECRET"
  export DEVAGENT_GITLAB_API="https://gitlab.example/api/v4"
  # Exit/parse status is irrelevant; the security property is what matters.
  run "$PLUGIN_ROOT/scripts/issue/gitlab.sh" fetch foo/bar 42
  grep -q . "$ARGV_FILE"                              # curl was actually invoked
  ! grep -q 'glpat-INTEGRATION-SECRET' "$ARGV_FILE"   # token NEVER in argv
  grep -q 'glpat-INTEGRATION-SECRET' "$STDIN_FILE"    # delivered via stdin config
}
