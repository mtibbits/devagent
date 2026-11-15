#!/usr/bin/env bats
# tests/file-tiers.bats — #1101: file.sh carries a capture's tiers.toml proposal
# to the tracker as tier:impl-<token> / tier:check-<token> labels, only where it
# departs from the project's class tier. The lib itself is tests/capture-tiers.bats;
# the disk round trip through pull.sh is in tests/disk-callers.bats.
bats_require_minimum_version 1.5.0

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/tp"
  CAP="$DEVDOC/Captures/idea"
  DRAFT="$CAP/draft.md"
  mkdir -p "$CAP" "$BATS_TEST_TMPDIR/tp-src"
  printf '# A captured idea\n\nBody.\n' > "$DRAFT"
  _config '[project.tp.step_models]' 'thinking = "opus"' 'checking = "opus"'

  # Stub backends: one bracketed element per argv word, logged to STUB_LOG.
  STUB_DIR="$BATS_TEST_TMPDIR/issue"
  STUB_LOG="$BATS_TEST_TMPDIR/backend.log"
  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/github.sh" <<EOF
#!/usr/bin/env bash
line=""; for a in "\$@"; do line+="[\$a] "; done
printf '%s\n' "\${line% }" >> "$STUB_LOG"
case "\$1" in
  state-exists)
    case " \${STUB_MISSING:-} " in *" \$3 "*) exit 4 ;; esac
    [ "\${STUB_LOOKUP_RC:-0}" != 78 ] || echo "not implemented" >&2
    exit "\${STUB_LOOKUP_RC:-0}" ;;
  create) echo "\${STUB_NUM:-7}" ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$STUB_DIR/github.sh"
  local b
  for b in gitlab jira acme; do cp "$STUB_DIR/github.sh" "$STUB_DIR/$b.sh"; done

  # Fake gh / glab: anything that runs them is a #87 violation.
  CLI_LOG="$BATS_TEST_TMPDIR/cli.log"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  for b in gh glab; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n' "$b" "$CLI_LOG" > "$BATS_TEST_TMPDIR/bin/$b"
    chmod +x "$BATS_TEST_TMPDIR/bin/$b"
  done
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  export DEVAGENT_DEVDOC_DIR="$DEVDOC"
  export DEVAGENT_ISSUE_BACKEND_DIR="$STUB_DIR"
  export DEVAGENT_PERMISSION_PUSH_MR=true
  unset DEVAGENT_ISSUE_BACKEND DEVAGENT_REPO_ORIGIN DEVAGENT_REPO_FORK DEVAGENT_PROJECT
}

teardown() { teardown_tmp_devagent_home; }

# _config [toml-lines…]: project tp owns DEVDOC; github o/r; the lines follow.
_config() {
  printf '%s\n' '[project.tp]' "source_dir = \"$BATS_TEST_TMPDIR/tp-src\"" "devdoc_dir = \"$DEVDOC\"" '' \
    '[project.tp.issue_source]' 'backend = "github"' 'repo = "o/r"' '' "$@" > "$DA_HOME/config.toml"
}

_tiers() { printf '%s\n' "$@" > "$CAP/tiers.toml"; }

_file() { run --separate-stderr "$PLUGIN_ROOT/scripts/capture/file.sh" --slug idea --target origin "$@"; }

# _tier_lines: the file.sh tier outcome lines on stderr, in order.
_tier_lines() { grep '^file\.sh: tier ' <<<"$stderr" || true; }

# ---------------------------------------------------------------- Task 2

@test "tiers: no tiers.toml files exactly as before" {
  _file
  [ "$status" -eq 0 ]
  [ "$output" = "https://github.com/o/r/issues/7" ]
  [ "$(cat "$STUB_LOG")" = "[create] [o/r] [A captured idea] [$DRAFT]" ]
  [ -z "$(_tier_lines)" ]
}

@test "tiers: no tiers.toml prints no labels line at a closed gate" {
  export DEVAGENT_PERMISSION_PUSH_MR=false
  _file
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"  body:    $DRAFT"* ]]
  [[ "$stderr" != *"labels:"* ]]
  [ ! -e "$STUB_LOG" ]
}

@test "tiers: an invalid tiers.toml exits 3 before any backend call, with no .pending" {
  local -a bodies=(
    'checking = "gpt"|checking must be one model token (sonnet opus haiku fable), got: '"'gpt'"
    'checking = "inherit"|checking = "inherit" is not a proposal'
    'colour = "red"|unknown key '"'colour'"
    'checking = fable|not valid TOML ('
    'checking = "fable inherit"|got: '"'fable inherit'"
    '[x]|[x] is not allowed'
    'checking = ""|got: '"''"
  )
  local row n=0
  for row in "${bodies[@]}"; do
    rm -f "$STUB_LOG" "$CAP/.pending" "$CAP/filed.toml"
    _tiers "${row%%|*}"
    _file
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"file.sh: $CAP/tiers.toml: "*"${row#*|}"* ]] || { echo "row: $row; stderr: $stderr" >&2; false; }
    [ ! -e "$STUB_LOG" ]
    [ ! -e "$CAP/.pending" ]
    [ ! -e "$CAP/filed.toml" ]
    n=$((n + 1))
  done
  [ "$n" -eq 7 ]
}

@test "tiers: an invalid tiers.toml exits 3, not 4, with the gate closed" {
  export DEVAGENT_PERMISSION_PUSH_MR=false
  _tiers 'checking = "gpt"'
  _file
  [ "$status" -eq 3 ]
  [[ "$stderr" != *"Permission gate"* ]]
  [ ! -e "$STUB_LOG" ]
}

@test "tiers: a tiers.toml that is a directory exits 3" {
  mkdir "$CAP/tiers.toml"
  _file
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"file.sh: $CAP/tiers.toml: not a regular readable file"* ]]
  [ ! -e "$STUB_LOG" ]
  [ ! -e "$CAP/.pending" ]
}

@test "tiers: a dangling tiers.toml symlink exits 3" {
  ln -s "$BATS_TEST_TMPDIR/nowhere" "$CAP/tiers.toml"
  _file
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"not a regular readable file"* ]]
  [ ! -e "$STUB_LOG" ]
}
