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

# _cfg_set <dotted-key> <value>: one config field, via _toml.py (#335: no sed -i on TOML).
_cfg_set() { python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" set "$DA_HOME/config.toml" "$1" "$2"; }

_file() { run --separate-stderr "$PLUGIN_ROOT/scripts/capture/file.sh" --slug idea --target origin; }

# _tier_lines: the file.sh tier outcome lines on stderr, in order.
# shellcheck disable=SC2154  # $stderr is set by `run --separate-stderr` (bats idiom)
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

@test "tiers: no tiers.toml keeps the gate plan byte-identical (D7)" {
  export DEVAGENT_PERMISSION_PUSH_MR=false
  _file
  [ "$status" -eq 4 ]
  local want
  want="Permission gate: push_mr=false

Plan:
  backend: github
  repo:    o/r
  title:   A captured idea
  body:    $DRAFT

Re-run with --yes to proceed, or set
[project.<name>.permissions].push_mr = true in config.toml."
  [ "$stderr" = "$want" ]
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

# ---------------------------------------------------------------- Task 3

GH_MISSING='not applied (label missing); add it to the issue before its first pull, after creating it:'

@test "tiers: a departing checking proposal is passed as --label (github)" {
  _tiers 'thinking = "opus"' 'checking = "fable"'
  _file
  [ "$status" -eq 0 ]
  [ "$output" = "https://github.com/o/r/issues/7" ]
  run cat "$STUB_LOG"
  [ "${lines[0]}" = "[state-exists] [o/r] [tier:check-fable]" ]
  [ "${lines[1]}" = "[create] [o/r] [A captured idea] [$DRAFT] [--label] [tier:check-fable]" ]
  [ "${#lines[@]}" -eq 2 ]
  [ "$(_tier_lines)" = "file.sh: tier thinking=opus: matches project tier
file.sh: tier checking=fable: applied as tier:check-fable" ]
}

@test "tiers: proposals equal to the project tiers file with no lookup and no label" {
  _tiers 'thinking = "opus"' 'checking = "opus"'
  _file
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_LOG")" = "[create] [o/r] [A captured idea] [$DRAFT]" ]
  [ "$(_tier_lines)" = "file.sh: tier thinking=opus: matches project tier
file.sh: tier checking=opus: matches project tier" ]
}

@test "tiers: with no step_models table any concrete proposal is labelled" {
  _config
  _tiers 'thinking = "opus"' 'checking = "fable"'
  _file
  [ "$status" -eq 0 ]
  run tail -n 1 "$STUB_LOG"
  [ "$output" = "[create] [o/r] [A captured idea] [$DRAFT] [--label] [tier:impl-opus] [--label] [tier:check-fable]" ]
}

@test "tiers: with only step_models.default each class is compared with default" {
  _config '[project.tp.step_models]' 'default = "opus"'
  _tiers 'thinking = "opus"' 'checking = "sonnet"'
  _file
  [ "$status" -eq 0 ]
  run tail -n 1 "$STUB_LOG"
  [ "$output" = "[create] [o/r] [A captured idea] [$DRAFT] [--label] [tier:check-sonnet]" ]
}

@test "tiers: a per-step override does not count" {
  _config '[project.tp.step_models]' '"16" = "fable"' 'checking = "opus"'
  _tiers 'checking = "fable"'
  _file
  [ "$status" -eq 0 ]
  run tail -n 1 "$STUB_LOG"
  [ "$output" = "[create] [o/r] [A captured idea] [$DRAFT] [--label] [tier:check-fable]" ]
}

@test "tiers: a missing GitHub label is left off and its create command printed" {
  export STUB_MISSING=tier:check-fable
  _tiers 'checking = "fable"'
  _file
  [ "$status" -eq 0 ]
  run tail -n 1 "$STUB_LOG"
  [ "$output" = "[create] [o/r] [A captured idea] [$DRAFT]" ]
  [ "$(_tier_lines)" = "file.sh: tier checking=fable: $GH_MISSING gh label create tier:check-fable --repo o/r" ]
  [ -f "$CAP/filed.toml" ]
  [ ! -e "$CAP/.pending" ]
  [ ! -e "$CLI_LOG" ]
}

@test "tiers: a missing GitLab label prints the glab command" {
  _config '[project.tp.step_models]' 'checking = "opus"'
  _cfg_set project.tp.issue_source.backend gitlab
  _cfg_set project.tp.issue_source.repo grp/proj
  export STUB_MISSING=tier:check-fable
  _tiers 'checking = "fable"'
  _file
  [ "$status" -eq 0 ]
  [ "$(_tier_lines)" = "file.sh: tier checking=fable: $GH_MISSING glab label create --name tier:check-fable --repo grp/proj" ]
  [ ! -e "$CLI_LOG" ]
}

@test "tiers: a custom backend reports a missing label with no command" {
  _cfg_set project.tp.issue_source.backend acme
  export STUB_MISSING=tier:check-fable
  _tiers 'checking = "fable"'
  _file
  [ "$status" -eq 0 ]
  [ "$(_tier_lines)" = "file.sh: tier checking=fable: not applied (label missing); add it to the issue before its first pull, after creating it on the tracker" ]
}

@test "tiers: a custom backend without state-exists files without the label" {
  _cfg_set project.tp.issue_source.backend acme
  export STUB_LOOKUP_RC=78
  _tiers 'checking = "fable"'
  _file
  [ "$status" -eq 0 ]
  [ "$(_tier_lines)" = "file.sh: tier checking=fable: not applied (lookup failed); state-exists exit 78" ]
  [[ "$stderr" == *"not implemented"* ]]
  run tail -n 1 "$STUB_LOG"
  [ "$output" = "[create] [o/r] [A captured idea] [$DRAFT]" ]
}

@test "tiers: any other lookup code files without the label, reports lookup failed and leaves no .pending" {
  local code n=0
  _tiers 'checking = "fable"'
  for code in 1 2 3; do
    rm -f "$STUB_LOG" "$CAP/filed.toml"
    export STUB_LOOKUP_RC="$code"
    _file
    [ "$status" -eq 0 ]
    [ "$(_tier_lines)" = "file.sh: tier checking=fable: not applied (lookup failed); state-exists exit $code" ]
    [ ! -e "$CAP/.pending" ]
    [ -f "$CAP/filed.toml" ]
    run tail -n 1 "$STUB_LOG"
    [ "$output" = "[create] [o/r] [A captured idea] [$DRAFT]" ]
    n=$((n + 1))
  done
  [ "$n" -eq 3 ]
}

@test "tiers: a mixed outcome resets the lookup code per class" {
  _config
  export STUB_MISSING=tier:impl-opus
  _tiers 'thinking = "opus"' 'checking = "fable"'
  _file
  [ "$status" -eq 0 ]
  run tail -n 1 "$STUB_LOG"
  [ "$output" = "[create] [o/r] [A captured idea] [$DRAFT] [--label] [tier:check-fable]" ]
  [ "$(_tier_lines)" = "file.sh: tier thinking=opus: $GH_MISSING gh label create tier:impl-opus --repo o/r
file.sh: tier checking=fable: applied as tier:check-fable" ]
}

@test "tiers: jira passes labels unchecked" {
  _cfg_set project.tp.issue_source.backend jira
  export STUB_NUM=ABC-12
  _tiers 'checking = "fable"'
  _file
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_LOG")" = "[create] [o/r] [A captured idea] [$DRAFT] [--label] [tier:check-fable]" ]
  [ "$(_tier_lines)" = "file.sh: tier checking=fable: applied as tier:check-fable" ]
}

@test "tiers: with the gate closed no lookup runs and the plan lists the labels" {
  export DEVAGENT_PERMISSION_PUSH_MR=false
  _tiers 'thinking = "opus"' 'checking = "fable"'
  _file
  [ "$status" -eq 4 ]
  [ ! -e "$STUB_LOG" ]
  [[ "$stderr" == *"  body:    $DRAFT
  labels:  tier:check-fable
"* ]]
  _tiers 'thinking = "opus"'
  _file
  [ "$status" -eq 4 ]
  [[ "$stderr" == *$'\n''  labels:  (none)'$'\n'* ]]
  : > "$CAP/tiers.toml"
  _file
  [ "$status" -eq 4 ]
  [[ "$stderr" == *$'\n''  labels:  (none)'$'\n'* ]]
  [ ! -e "$STUB_LOG" ]
}

@test "tiers: the plan lists every departing label space-separated" {
  export DEVAGENT_PERMISSION_PUSH_MR=false
  _tiers 'thinking = "sonnet"' 'checking = "fable"'
  _file
  [ "$status" -eq 4 ]
  [[ "$stderr" == *$'\n''  labels:  tier:impl-sonnet tier:check-fable'$'\n'* ]]
}

@test "tiers: a devdoc owned by no single project files with no tier labels" {
  export DEVAGENT_ISSUE_BACKEND=github DEVAGENT_REPO_ORIGIN=o/r
  _tiers 'thinking = "sonnet"' 'checking = "fable"'
  local leg
  for leg in none shared; do
    rm -f "$STUB_LOG" "$CAP/filed.toml"
    if [ "$leg" = none ]; then
      _cfg_set project.tp.devdoc_dir "$BATS_TEST_TMPDIR/elsewhere"
    else
      _config '[project.tp.step_models]' 'checking = "opus"'
      printf '%s\n' '[project.tp2]' "devdoc_dir = \"$DEVDOC\"" >> "$DA_HOME/config.toml"
    fi
    _file
    [ "$status" -eq 0 ]
    [ "$(cat "$STUB_LOG")" = "[create] [o/r] [A captured idea] [$DRAFT]" ]
    [ "$(_tier_lines)" = "file.sh: tier thinking=sonnet: not applied (no project)
file.sh: tier checking=fable: not applied (no project)" ]
  done
  export DEVAGENT_PERMISSION_PUSH_MR=false
  rm -f "$CAP/filed.toml"
  _file
  [ "$status" -eq 4 ]
  [[ "$stderr" == *$'\n''  labels:  (none; not applied (no project))'$'\n'* ]]
}

@test "tiers: under crrf's env the project still comes from the devdoc" {
  _config '[project.tp.step_models]' 'checking = "opus"' '' \
    '[project.decoy]' "devdoc_dir = \"$BATS_TEST_TMPDIR/devDoc/decoy\"" '' \
    '[project.decoy.step_models]' 'checking = "fable"'
  mkdir -p "$BATS_TEST_TMPDIR/devDoc/decoy"
  export DEVAGENT_ISSUE_BACKEND=github DEVAGENT_REPO_ORIGIN=o/r DEVAGENT_PROJECT=decoy
  _tiers 'checking = "fable"'
  _file
  [ "$status" -eq 0 ]
  run tail -n 1 "$STUB_LOG"
  [ "$output" = "[create] [o/r] [A captured idea] [$DRAFT] [--label] [tier:check-fable]" ]
}

@test "tiers: every outcome line matches the grammar and crrf.md's vocabulary" {
  local re='^file\.sh: tier (thinking|checking)=[A-Za-z0-9._-]+: (applied as tier:(impl|check)-[A-Za-z0-9._-]+|matches project tier|not applied \((label missing|lookup failed|no project)\)(; .+)?)$'
  local all="" crrf l n=0 phrase
  crrf="$(<"$PLUGIN_ROOT/commands/crrf.md")"
  # applied + matches
  _tiers 'thinking = "opus"' 'checking = "fable"'
  _file; [ "$status" -eq 0 ]; all+="$(_tier_lines)"$'\n'
  # label missing
  rm -f "$CAP/filed.toml"; export STUB_MISSING=tier:check-fable
  _file; [ "$status" -eq 0 ]; all+="$(_tier_lines)"$'\n'
  # lookup failed
  rm -f "$CAP/filed.toml"; unset STUB_MISSING; export STUB_LOOKUP_RC=1
  _file; [ "$status" -eq 0 ]; all+="$(_tier_lines)"$'\n'
  # no project
  rm -f "$CAP/filed.toml"; unset STUB_LOOKUP_RC
  export DEVAGENT_ISSUE_BACKEND=github DEVAGENT_REPO_ORIGIN=o/r
  _cfg_set project.tp.devdoc_dir "$BATS_TEST_TMPDIR/elsewhere"
  _file; [ "$status" -eq 0 ]; all+="$(_tier_lines)"
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    [[ "$l" =~ $re ]] || { echo "off-grammar: $l" >&2; false; }
    phrase="${l#file.sh: tier *=*: }"
    case "$phrase" in
      applied\ as*) phrase="applied as" ;;
      not\ applied*) phrase="${phrase%%)*})" ;;
    esac
    [[ "$crrf" == *"$phrase"* ]] || { echo "crrf.md lacks: $phrase" >&2; false; }
    n=$((n + 1))
  done <<<"$all"
  [ "$n" -ge 5 ]
  [[ "$all" == *"applied as tier:check-fable"* ]]
  [[ "$all" == *"matches project tier"* ]]
  [[ "$all" == *"not applied (label missing)"* ]]
  [[ "$all" == *"not applied (lookup failed)"* ]]
  [[ "$all" == *"not applied (no project)"* ]]
}

@test "file.md documents tiers.toml, the outcomes, replace-don't-add and #87" {
  local f="$PLUGIN_ROOT/commands/file.md"
  grep -q 'tiers.toml' "$f"
  grep -q 'gh label create' "$f"
  grep -q 'glab label create' "$f"
  grep -q '#87' "$f"
  grep -qE 'two .*pull|pull.*two ' "$f"
  grep -q 'invalid `tiers.toml`' "$f"
  grep -q 'GITLAB_HOST' "$f"
  grep -qi 'lowercase' "$f"
  grep -q '#1042' "$f"
  grep -q 'file.sh: tier ' "$f"
  grep -q 'state-exists' "$f"
}

@test "spec names tiers.toml in the capture tree and file.sh as a label writer" {
  local s="$PLUGIN_ROOT/docs/specs/2026-05-19-devagent-plugin-design.md"
  grep -q '^├── tiers.toml .*#1101' "$s"
  grep -q 'file.sh.*departing' "$s"
}

@test "CHANGELOG: only github and gitlab print a create command for a missing label" {
  local e
  e="$(awk '/capture-time model-tier proposals \(#1101\)/{f=1} f&&/^- \*\*/&&!/#1101/{exit} f' "$PLUGIN_ROOT/CHANGELOG.md")"
  [ -n "$e" ]
  [[ "$e" == *"github and gitlab print its create command"* ]]
}
