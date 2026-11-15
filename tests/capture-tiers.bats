#!/usr/bin/env bats
# #1101: scripts/capture/lib/tiers.sh — the capture-time tier proposal reader
# (tiers_read), the project class-tier lookup (tiers_class_tier) and the label
# shape (tiers_label). file.sh's use of them is pinned in tests/file-tiers.bats.
bats_require_minimum_version 1.5.0

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  printf '[project.p]\nsource_dir = "/tmp/p"\n' > "$DA_HOME/config.toml"
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/config.sh"
  source "$PLUGIN_ROOT/scripts/lib/flags.sh"
  source "$PLUGIN_ROOT/scripts/capture/lib/tiers.sh"
  T="$DA_HOME/tiers.toml"
}

teardown() { teardown_tmp_devagent_home; }

_tiers() { printf '%s\n' "$1" > "$T"; }
_models() { printf '[project.p.step_models]\n%s\n' "$1" >> "$DA_HOME/config.toml"; }

# ---- tiers_read --------------------------------------------------------------

@test "read: both classes" {
  _tiers 'thinking = "sonnet"
checking = "fable"'
  rc=0; tiers_read "$T" || rc=$?
  [ "$rc" -eq 0 ]
  [ "$TIERS_THINKING" = "sonnet" ]
  [ "$TIERS_CHECKING" = "fable" ]
}

@test "read: one class leaves the other empty" {
  _tiers 'checking = "fable"'
  rc=0; tiers_read "$T" || rc=$?
  [ "$rc" -eq 0 ]
  [ "$TIERS_THINKING" = "" ]
  [ "$TIERS_CHECKING" = "fable" ]
}

@test "read: reasons accepted and not returned" {
  _tiers 'checking = "fable"
reason_checking = "the review needs the strongest model"
reason_thinking = "nothing unusual"'
  rc=0; tiers_read "$T" || rc=$?
  [ "$rc" -eq 0 ]
  [ "$TIERS_THINKING" = "" ]
  [ "$TIERS_CHECKING" = "fable" ]
}

@test "read: an empty file is no proposal" {
  : > "$T"
  rc=0; tiers_read "$T" || rc=$?
  [ "$rc" -eq 0 ]
  [ "$TIERS_THINKING" = "" ]
  [ "$TIERS_CHECKING" = "" ]
}

@test "read: stale globals from the env are cleared" {
  export TIERS_CHECKING=opus TIERS_ERR=stale
  _tiers 'thinking = "haiku"'
  rc=0; tiers_read "$T" || rc=$?
  [ "$rc" -eq 0 ]
  [ "$TIERS_THINKING" = "haiku" ]
  [ "$TIERS_CHECKING" = "" ]
  [ "$TIERS_ERR" = "" ]
}

@test "read: CRLF file reads the same tokens" {
  printf 'thinking = "sonnet"\r\nchecking = "fable"\r\n' > "$T"
  rc=0; tiers_read "$T" || rc=$?
  [ "$rc" -eq 0 ]
  [ "$TIERS_THINKING" = "sonnet" ]
  [ "$TIERS_CHECKING" = "fable" ]
}

@test "read: an illegal token names the class and the legal set" {
  _tiers 'checking = "gpt"'
  rc=0; tiers_read "$T" || rc=$?
  [ "$rc" -eq 1 ]
  [ "$TIERS_ERR" = "$T: checking must be one model token (sonnet opus haiku fable), got: 'gpt'" ]
  [ "$TIERS_CHECKING" = "" ]
}

@test "read: inherit is refused with its own message" {
  _tiers 'thinking = "inherit"'
  rc=0; tiers_read "$T" || rc=$?
  [ "$rc" -eq 1 ]
  [ "$TIERS_ERR" = "$T: thinking = \"inherit\" is not a proposal; omit the key to keep the project tier" ]
}

@test "read: a present but empty class value is refused" {
  _tiers 'checking = ""'
  rc=0; tiers_read "$T" || rc=$?
  [ "$rc" -eq 1 ]
  [ "$TIERS_ERR" = "$T: checking must be one model token (sonnet opus haiku fable), got: ''" ]
}

@test "read: a multi-token value is refused although model_token_is_legal accepts it" {
  local v
  for v in "fable inherit" "opus haiku"; do
    model_token_is_legal "$v"
    _tiers "checking = \"$v\""
    rc=0; tiers_read "$T" || rc=$?
    [ "$rc" -eq 1 ]
    [ "$TIERS_ERR" = "$T: checking must be one model token (sonnet opus haiku fable), got: '$v'" ]
  done
}

@test "read: non-string class values are refused" {
  _tiers 'checking = 3'
  rc=0; tiers_read "$T" || rc=$?
  [ "$rc" -eq 1 ]
  [ "$TIERS_ERR" = "$T: checking must be one model token (sonnet opus haiku fable), got: '3'" ]
  _tiers 'checking = ["fable"]'
  rc=0; tiers_read "$T" || rc=$?
  [ "$rc" -eq 1 ]
  [ "$TIERS_ERR" = "$T: checking must be one model token (sonnet opus haiku fable), got: '[\"fable\"]'" ]
}

@test "read: unknown key is refused" {
  _tiers 'checkng = "fable"'
  rc=0; tiers_read "$T" || rc=$?
  [ "$rc" -eq 1 ]
  [ "$TIERS_ERR" = "$T: unknown key 'checkng' (keys: thinking, checking, reason_thinking, reason_checking)" ]
}

@test "read: tables and dotted keys are refused" {
  _tiers '[extra]
x = "y"'
  rc=0; tiers_read "$T" || rc=$?
  [ "$rc" -eq 1 ]
  [ "$TIERS_ERR" = "$T: [extra] is not allowed (keys: thinking, checking, reason_thinking, reason_checking)" ]
  _tiers 'a.b = "x"'
  rc=0; tiers_read "$T" || rc=$?
  [ "$rc" -eq 1 ]
  [ "$TIERS_ERR" = "$T: [a] is not allowed (keys: thinking, checking, reason_thinking, reason_checking)" ]
}

@test "read: malformed TOML is rc 1 with no traceback" {
  _tiers 'checking = fable'
  rc=0; tiers_read "$T" 2> "$DA_HOME/err" || rc=$?
  [ "$rc" -eq 1 ]
  [[ "$TIERS_ERR" == "$T: not valid TOML ("* ]]
  [[ "$TIERS_ERR" == *")" ]]
  run grep -c Traceback "$DA_HOME/err"
  [ "$output" = "0" ]
}

@test "read: a directory is rc 1" {
  mkdir "$DA_HOME/dir"
  rc=0; tiers_read "$DA_HOME/dir" || rc=$?
  [ "$rc" -eq 1 ]
  [ "$TIERS_ERR" = "$DA_HOME/dir: not a regular readable file" ]
}

# ---- tiers_class_tier ----------------------------------------------------------

@test "class_tier: the class key beats default" {
  _models 'checking = "fable"
default = "sonnet"'
  rc=0; tiers_class_tier p checking || rc=$?
  [ "$rc" -eq 0 ]
  [ "$TIERS_RESOLVED" = "fable" ]
}

@test "class_tier: default fills an absent class" {
  _models 'default = "sonnet"'
  rc=0; tiers_class_tier p thinking || rc=$?
  [ "$rc" -eq 0 ]
  [ "$TIERS_RESOLVED" = "sonnet" ]
}

@test "class_tier: an empty class value falls to default" {
  _models 'checking = ""
default = "sonnet"'
  rc=0; tiers_class_tier p checking || rc=$?
  [ "$rc" -eq 0 ]
  [ "$TIERS_RESOLVED" = "sonnet" ]
}

@test "class_tier: no table resolves empty with rc 0" {
  export TIERS_RESOLVED=stale
  rc=0; tiers_class_tier p checking || rc=$?
  [ "$rc" -eq 0 ]
  [ "$TIERS_RESOLVED" = "" ]
}

@test "class_tier: a per-step key is never read" {
  _models '"16" = "fable"
checking = "opus"'
  rc=0; tiers_class_tier p checking || rc=$?
  [ "$rc" -eq 0 ]
  [ "$TIERS_RESOLVED" = "opus" ]
}

@test "class_tier: a table-valued class falls to default" {
  printf '[project.p.step_models]\ndefault = "haiku"\n[project.p.step_models.checking]\nx = "y"\n' \
    >> "$DA_HOME/config.toml"
  rc=0; tiers_class_tier p checking || rc=$?
  [ "$rc" -eq 0 ]
  [ "$TIERS_RESOLVED" = "haiku" ]
}

@test "class_tier: inherit is returned verbatim" {
  _models 'checking = "inherit"'
  rc=0; tiers_class_tier p checking || rc=$?
  [ "$rc" -eq 0 ]
  [ "$TIERS_RESOLVED" = "inherit" ]
}

@test "class_tier: CRLF config reads the same token" {
  printf '[project.p.step_models]\r\nchecking = "opus"\r\n' >> "$DA_HOME/config.toml"
  rc=0; tiers_class_tier p checking || rc=$?
  [ "$rc" -eq 0 ]
  [ "$TIERS_RESOLVED" = "opus" ]
}

@test "class_tier: an unreadable config is rc 2, never a fallback" {
  _models 'default = "sonnet"'
  printf 'this is = = not toml\n' >> "$DA_HOME/config.toml"
  rc=0; tiers_class_tier p checking || rc=$?
  [ "$rc" -eq 2 ]
  [ "$TIERS_RESOLVED" = "" ]
  [ "$TIERS_ERR" = "could not read [project.p.step_models] (config rc 2)" ]
}

@test "class_tier agrees with step_models_tier on every fixture without a per-step key" {
  local base n=0 i cls step want
  base="$(cat "$DA_HOME/config.toml")"
  local -a fx=(
    ''
    'default = "sonnet"'
    'checking = "fable"
thinking = "opus"'
    'checking = "fable"
default = "haiku"'
    'default = "inherit"'
    'checking = ""
thinking = ""
default = "opus"'
    'default = "haiku"
[project.p.step_models.checking]
x = "y"
[project.p.step_models.thinking]
x = "y"'
  )
  for i in "${!fx[@]}"; do
    printf '%s\n' "$base" > "$DA_HOME/config.toml"
    [ -z "${fx[$i]}" ] || _models "${fx[$i]}"
    for cls in thinking checking; do
      step=2; [ "$cls" = checking ] && step=5
      rc=0; want="$(step_models_tier p "$step" 2>/dev/null)" || rc=$?
      [ "$rc" -ne 3 ] || want=""
      [ "$rc" -ne 2 ] || want="inherit"
      rc=0; tiers_class_tier p "$cls" || rc=$?
      [ "$rc" -eq 0 ]
      [ "$TIERS_RESOLVED" = "$want" ]
      n=$((n + 1))
    done
  done
  [ "$n" -eq 14 ]
}

# ---- tiers_label ---------------------------------------------------------------

@test "label: shapes are pull.sh's" {
  run tiers_label thinking fable
  [ "$output" = "tier:impl-fable" ]
  run tiers_label checking fable
  [ "$output" = "tier:check-fable" ]
}

# ---- Task 4: the propose step's one home (skills/capture/SKILL.md) -------------

@test "capture SKILL documents the propose step" {
  local s="$PLUGIN_ROOT/skills/capture/SKILL.md" k
  run grep -c '^## Propose model tiers$' "$s"
  [ "$output" = "1" ]
  for k in thinking checking reason_thinking reason_checking; do
    grep -q "^$k = \"" "$s"
  done
  grep -q 'never `inherit`' "$s"
  grep -q 'An epic draft gets no tier proposal' "$s"
  grep -q 'model_token_allowlist' "$s"
  grep -qi 'reaped' "$s"
}

@test "capture SKILL anchors the propose step after the draft body is written, rerun on revise" {
  local s="$PLUGIN_ROOT/skills/capture/SKILL.md" body propose
  grep -q 'after the draft body is written' "$s"
  grep -qi 'revise' "$s"
  body="$(grep -n 'after the draft body is written' "$s" | head -n 1 | cut -d: -f1)"
  propose="$(grep -n '^## Propose model tiers$' "$s" | cut -d: -f1)"
  [ "$body" -lt "$propose" ]
}

@test "capture SKILL proposes only an argued departure" {
  local s="$PLUGIN_ROOT/skills/capture/SKILL.md"
  grep -q 'omit the key' "$s"
  grep -q 'step_models' "$s"
}

@test "capture SKILL hard-codes no model token list" {
  run grep -cE 'sonnet[ ,`]+opus[ ,`]+haiku[ ,`]+fable' "$PLUGIN_ROOT/skills/capture/SKILL.md"
  [ "$output" = "0" ]
}
