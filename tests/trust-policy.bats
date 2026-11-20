#!/usr/bin/env bats
# #713 task 3: scripts/lib/trust_policy.py — load, validate, normalise, digest
# and canonical key. Exit 0 ok · 2 usage · 3 defect (one-line reason on stderr).

bats_require_minimum_version 1.5.0   # run --separate-stderr
load 'lib/bats-helpers'
load 'lib/trust-fixture'

setup() {
  P="$BATS_TEST_TMPDIR/trust"
}

# _refuses <needle> [load args…]: load must exit 3 with <needle> on stderr.
_refuses() {
  local needle="$1"
  shift
  run --separate-stderr trust_py load "$P" "$@"
  [ "$status" -eq 3 ] || { echo "rc=$status out=$output err=$stderr" >&2; return 1; }
  [[ "$stderr" == *"$needle"* ]] || { echo "stderr: $stderr" >&2; return 1; }
  [ "$output" = "" ]
}

@test "policy: refuses a display-name-shaped entry" {
  trust_fixture_policy "$P" 'scopes = ["github:github.com/acme/widgets"]' 'worker_identities = ["github:Matt Tibbits"]'
  _refuses "identity entry 'github:Matt Tibbits' is not an immutable github id"
}

@test "policy: refuses a login-shaped entry" {
  trust_fixture_policy "$P" 'scopes = ["github:github.com/acme/widgets"]' 'worker_identities = ["github:1001"]' 'trusted_approvers = ["github:mtibbits"]'
  _refuses "identity entry 'github:mtibbits' is not an immutable github id"
}

@test "policy: refuses an unknown key" {
  trust_fixture_policy "$P" "${TRUST_FIXTURE_MIN[@]}" 'trust = false'
  _refuses "unknown key 'trust'"
}

@test "policy: refuses a wrongly typed key" {
  trust_fixture_policy "$P" "${TRUST_FIXTURE_MIN[@]}" 'push_mr = "yes"'
  _refuses "key 'push_mr' must be a boolean"
}

@test "policy: refuses an empty worker_identities and a missing scopes" {
  trust_fixture_policy "$P" 'scopes = ["github:github.com/acme/widgets"]' 'worker_identities = []'
  _refuses "worker_identities must be non-empty"
  trust_fixture_policy "$P" 'worker_identities = ["github:1001"]'
  _refuses "scopes must be non-empty"
}

@test "policy: refuses a policy under devagent_home" {
  local DA_HOME="$BATS_TEST_TMPDIR/home/.config/devagent"
  P="$DA_HOME/trust"
  trust_fixture_policy "$P"
  _refuses "is under a forbidden root" --forbid "$DA_HOME"
  # positive control: without the forbid root it loads.
  run trust_py load "$P"
  [ "$status" -eq 0 ]
}

@test "policy: refuses an unreadable file" {
  [ "$(id -u)" -ne 0 ] || skip "euid 0 reads a mode-000 file"
  trust_fixture_policy "$P"
  chmod 000 "$P/policy.toml"
  [ ! -r "$P/policy.toml" ] || skip "this filesystem cannot represent mode 000 (noacl)"
  _refuses "cannot read"
}

@test "policy: refuses a dangling link" {
  mkdir -p "$P"
  ln -s "$BATS_TEST_TMPDIR/nowhere.toml" "$P/policy.toml" 2>/dev/null     && [ -L "$P/policy.toml" ] || skip "this filesystem cannot make a dangling symlink"
  _refuses "dangling link"
}

@test "policy: refuses invalid TOML" {
  trust_fixture_policy "$P" 'scopes = ["github:github.com/acme/widgets"' 'worker_identities = '
  _refuses "invalid TOML"
}

@test "policy: refuses a second *.toml beside policy.toml" {
  trust_fixture_policy "$P"
  : > "$P/extra.toml"
  _refuses "another policy file extra.toml beside policy.toml"
}

@test "policy: refuses worker∩approver with single_identity false" {
  trust_fixture_policy "$P" "${TRUST_FIXTURE_MIN[@]}" 'trusted_approvers = ["github:1001"]'
  _refuses "github:1001 is in worker_identities and trusted_approvers"
}

@test "policy: refuses code_host_workers∩trusted_reviewers with single_identity false" {
  trust_fixture_policy "$P" "${TRUST_FIXTURE_MIN[@]}" 'code_host_workers = ["github:7"]' 'trusted_reviewers = ["github:7"]'
  _refuses "github:7 is in code_host_workers and trusted_reviewers"
}

@test "policy: refuses an unknown required_hardening member" {
  trust_fixture_policy "$P" "${TRUST_FIXTURE_MIN[@]}" 'required_hardening = ["firewall"]'
  _refuses "required_hardening member 'firewall' is not one of signatures, separate_identity, system_policy"
}

@test "policy: worker∩approver accepted with single_identity true" {
  trust_fixture_policy "$P" "${TRUST_FIXTURE_MIN[@]}" 'trusted_approvers = ["github:1001"]' 'single_identity = true'
  run --separate-stderr trust_py load "$P"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'id\ttrusted_approvers\tgithub:1001'* ]]
  [[ "$output" == *$'val\tsingle_identity\ttrue'* ]]
}

@test "policy: load emits every kind with no empty field" {
  trust_fixture_policy "$P" "${TRUST_FIXTURE_MIN[@]}" \
    'trusted_approvers = ["jira:5b10ac8d82e05b22cc7d4ef5", "jira:557058:f58131cb-b67d-43c7-b30d-6b58d40bd077"]'
  run --separate-stderr trust_py load "$P"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'digest\t-\tsha256:'* ]]
  [[ "$output" == *$'file\t-\t'*"/policy.toml"* ]]
  [[ "$output" == *$'scope\t-\tgithub:github.com/acme/widgets'* ]]
  [[ "$output" == *$'id\tworker_identities\tgithub:1001'* ]]
  [[ "$output" == *$'id\ttrusted_approvers\tjira:557058:f58131cb-b67d-43c7-b30d-6b58d40bd077'* ]]
  [[ "$output" == *$'val\tpush_mr\tfalse'* ]]
  [[ "$output" == *$'val\trequire_user_verification\ttrue'* ]]
  run awk -F'\t' 'NF != 3 || $1 == "" || $2 == "" || $3 == ""' <<<"$output"
  [ "$output" = "" ]
}

@test "policy: get prints one key's normalised value" {
  trust_fixture_policy "$P" "${TRUST_FIXTURE_MIN[@]}" 'merge_mr = true'
  run trust_py get "$P" merge_mr
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  run trust_py get "$P" required_hardening
  [ "$output" = "[]" ]
  run trust_py get "$P" no_such_key
  [ "$status" -eq 2 ]
}

@test "policy: parses with tomli when tomllib is absent" {
  python3 -I -c 'import tomli' 2>/dev/null || skip "tomli is not installed on this host"
  trust_fixture_policy "$P"
  run python3 -I -X utf8 -c "import sys, runpy; sys.modules['tomllib'] = None; sys.argv = ['trust_policy.py', 'load', sys.argv[1]]; runpy.run_path('$TRUST_PY', run_name='__main__')" "$P"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'id\tworker_identities\tgithub:1001'* ]]
}

@test "output: load emits LF only, no CR byte" {
  trust_fixture_policy "$P"
  trust_py load "$P" > "$BATS_TEST_TMPDIR/out"
  [ -s "$BATS_TEST_TMPDIR/out" ]
  run grep -c . "$BATS_TEST_TMPDIR/out"
  [ "$output" -ge 4 ]
  run bash -c "od -c '$BATS_TEST_TMPDIR/out' | grep -F '\\r'"
  [ "$status" -eq 1 ]
}

_digest() { trust_py load "$1" | awk -F'\t' '$1 == "digest" { print $3 }'; }

@test "digest: differing copies differ" {
  trust_fixture_policy "$P/a"
  trust_fixture_policy "$P/b" "${TRUST_FIXTURE_MIN[@]}" 'merge_mr = true'
  local a b
  a="$(_digest "$P/a")"; b="$(_digest "$P/b")"
  [[ "$a" == sha256:* ]]
  [ "$a" != "$b" ]
}

@test "digest: key order, whitespace and explicit defaults leave it unchanged" {
  trust_fixture_policy "$P/a" 'scopes = ["github:github.com/acme/widgets"]' 'worker_identities = ["github:1001", "github:1002"]'
  trust_fixture_policy "$P/b" '  worker_identities   =   [ "github:1002" , "github:1001", "github:1001" ]' '' \
    'single_identity = false' 'push_mr = false' 'revoking = []' 'scopes = ["github:github.com/acme/widgets"]'
  local a
  a="$(_digest "$P/a")"
  [[ "$a" == sha256:* ]]
  [ "$a" = "$(_digest "$P/b")" ]
}

@test "key: canonical repo and issue keys" {
  local backend repo num host want got
  while IFS='|' read -r backend repo num host want; do
    [ -n "$backend" ] || continue
    got="$(trust_py key "$backend" "$repo" ${num:+"$num"} ${host:+--host "$host"})"
    [ "$got" = "$want" ] || { echo "key $backend $repo $num $host → '$got', want '$want'" >&2; return 1; }
  done <<'EOF'
github|mtibbits/devagent|705||github:github.com/mtibbits/devagent#705
github|MTibbits/DevAgent.git|||github:github.com/mtibbits/devagent
github|https://github.com/mtibbits/devagent/|||github:github.com/mtibbits/devagent
github|git@github.com:mtibbits/devagent.git|||github:github.com/mtibbits/devagent
github|ghe.corp/Team/Tool|007||github:ghe.corp/team/tool#7
github|team/tool||ghe.corp|github:ghe.corp/team/tool
gitlab|Group/Sub/Proj|12|https://gitlab.example.com/api/v4|gitlab:gitlab.example.com/group/sub/proj#12
gitlab|group/proj|||gitlab:gitlab.com/group/proj
jira|proj|12|https://Example.atlassian.net/|jira:example.atlassian.net/PROJ-12
jira|PROJ||https://jira.corp/Jira|jira:jira.corp/jira/PROJ
EOF
  # distinctness: origin≠fork, two repos, two JIRA sites.
  [ "$(trust_py key github gnuradio/volk)" != "$(trust_py key github mtibbits/volk)" ]
  [ "$(trust_py key github acme/a)" != "$(trust_py key github acme/b)" ]
  [ "$(trust_py key jira PROJ --host https://a.atlassian.net)" != "$(trust_py key jira PROJ --host https://b.atlassian.net)" ]
}

@test "key: refuses an owner-level repo and a zero issue number" {
  run --separate-stderr trust_py key github mtibbits
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"repo 'mtibbits' is not OWNER/REPO"* ]]
  run --separate-stderr trust_py key github mtibbits/devagent 0
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"issue number '0'"* ]]
}

@test "scope: an owner-level scope is refused" {
  trust_fixture_policy "$P" 'scopes = ["github:github.com/mtibbits"]' 'worker_identities = ["github:1001"]'
  _refuses "scope 'github:github.com/mtibbits' is not an exact repo key"
}

@test "scope: scopes are normalised to the canonical key" {
  trust_fixture_policy "$P" 'scopes = ["github:GitHub.com/MTibbits/DevAgent.git"]' 'worker_identities = ["github:1001"]'
  run trust_py load "$P"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'scope\t-\tgithub:github.com/mtibbits/devagent'* ]]
}

@test "scope: a jira scope without trackers.jira.base_url is a defect" {
  trust_fixture_policy "$P" 'scopes = ["jira:corp.atlassian.net/PROJ"]' 'worker_identities = ["github:1001"]'
  _refuses "a jira scope needs trackers.jira.base_url"
  trust_fixture_policy "$P" 'scopes = ["jira:corp.atlassian.net/PROJ"]' 'worker_identities = ["github:1001"]' \
    'trackers = { jira = { base_url = "https://corp.atlassian.net" } }'
  run trust_py load "$P"
  [ "$status" -eq 0 ]
}

# --- #715: allowed_steering (type steering) and size_cap

# _steering_all: the 38 legal entries, built here from flags.sh's allowlists
# (not from trust_policy.py), one per line.
_steering_all() {
  ( # shellcheck source=/dev/null
    source "$PLUGIN_ROOT/scripts/lib/flags.sh"
    local t m
    for t in $(tier_allowlist); do echo "tier: $t"; done
    for m in $(model_token_allowlist); do
      echo "tier: $m-checking"
      echo "implementation-model: $m"
      echo "checking-model: $m"
      echo "tier:impl-$m"
      echo "tier:check-$m"
      echo "tier:$m-checking"
    done
    echo "research: required"
    echo "spike: required" )
}

# _toml_list <lines on stdin>: a TOML array of basic strings.
_toml_list() {
  local e out="" sep=""
  while IFS= read -r e; do out+="$sep\"$e\""; sep=", "; done
  printf '[%s]' "$out"
}

# _val <key>: the JSON value `load` printed for <key> (after `run trust_py load`).
_val() { awk -F'\t' -v k="$1" '$1 == "val" && $2 == k { print $3 }' <<<"$output"; }

@test "steering: all 38 legal entries load" {
  local list
  list="$(_steering_all)"
  [ "$(grep -c . <<<"$list")" -eq 38 ]
  trust_fixture_policy "$P" "${TRUST_FIXTURE_MIN[@]}" "allowed_steering = $(_toml_list <<<"$list")"
  run --separate-stderr trust_py load "$P"
  [ "$status" -eq 0 ] || { echo "rc=$status err=$stderr" >&2; return 1; }
  local got
  got="$(_val allowed_steering | python3 -c 'import json, sys; print("\n".join(json.load(sys.stdin)))')"
  [ "$(grep -c . <<<"$got")" -eq 38 ]
  [ "$(sort <<<"$got")" = "$(sort <<<"$list")" ]
}

@test "steering: each legal entry satisfies the real consumer" {
  # shellcheck source=/dev/null
  source "$PLUGIN_ROOT/scripts/lib/flags.sh"
  local vocab e key val n=0 rows
  # shellcheck disable=SC2016
  vocab="$(python3 -I -X utf8 -c 'import importlib.util as u, sys
s = u.spec_from_file_location("tp", sys.argv[1]); m = u.module_from_spec(s); s.loader.exec_module(m)
print("\n".join(sorted(m.steering_vocabulary())))' "$TRUST_PY" | tr -d '\r')"
  [ "$(grep -c . <<<"$vocab")" -eq 38 ]
  # pull.sh's optional-row table: the research / spike trigger values.
  rows="$(grep -oE '"(research|spike):[a-z]+:[0-9]+"' "$PLUGIN_ROOT/scripts/pull.sh" | tr -d '"')"
  [ "$(grep -c . <<<"$rows")" -eq 2 ]
  while IFS= read -r e; do
    n=$((n + 1))
    case "$e" in
      tier:impl-*)  model_token_is_legal "${e#tier:impl-}" ;;
      tier:check-*) model_token_is_legal "${e#tier:check-}" ;;
      "tier: "*)    val="${e#tier: }"; tier_is_legal "$val" || tier_shim_model "$val" >/dev/null ;;
      tier:*-checking) val="${e#tier:}"; model_token_is_legal "${val%-checking}" ;;
      *": "*)
        key="${e%%: *}"; val="${e#*: }"
        [[ " $(flags_known_keys) " == *" $key "* ]] || { echo "unknown key: $e" >&2; return 1; }
        case "$key" in
          implementation-model|checking-model) model_token_is_legal "$val" ;;
          research|spike) grep -qE "^$key:$val:[0-9]+\$" <<<"$rows" ;;
          *) echo "unexpected key: $e" >&2; return 1 ;;
        esac ;;
      *) echo "unexpected shape: $e" >&2; return 1 ;;
    esac || { echo "consumer rejects: $e" >&2; return 1; }
  done <<<"$vocab"
  [ "$n" -eq 38 ]
}

@test "steering: illegal entries refuse" {
  local e
  for e in 'tier:oneshot' 'tier: bogus' 'tier: oneshot ' 'research: yes' 'tier:impl-opus-checking' \
           'checking-model: gpt' 'foo: bar' '' '*'; do
    trust_fixture_policy "$P" "${TRUST_FIXTURE_MIN[@]}" "allowed_steering = [\"tier: standard\", \"$e\"]"
    _refuses "allowed_steering entry '$e' is not a legal steering value"
  done
}

@test "steering: unset loads as []" {
  trust_fixture_policy "$P"
  run --separate-stderr trust_py load "$P"
  [ "$status" -eq 0 ]
  [ "$(_val allowed_steering)" = "[]" ]
}

@test "size_cap: unset loads as 65536" {
  trust_fixture_policy "$P"
  run --separate-stderr trust_py load "$P"
  [ "$status" -eq 0 ]
  [ "$(_val size_cap)" = "65536" ]
}

@test "size_cap: 2147483647 loads, 2147483648 refuses" {
  trust_fixture_policy "$P" "${TRUST_FIXTURE_MIN[@]}" 'size_cap = 2147483647'
  run --separate-stderr trust_py load "$P"
  [ "$status" -eq 0 ]
  [ "$(_val size_cap)" = "2147483647" ]
  trust_fixture_policy "$P" "${TRUST_FIXTURE_MIN[@]}" 'size_cap = 2147483648'
  _refuses "size_cap must be at most 2147483647"
}

@test "steering: a flags.sh without its allowlist line is a defect" {
  local lib="$BATS_TEST_TMPDIR/lib"
  cp -r "$PLUGIN_ROOT/scripts/lib" "$lib"
  # Split the one-line tier_allowlist literal in two: the reader finds 0 lines.
  python3 - "$lib/flags.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = "tier_allowlist() { printf 'oneshot standard perf docs-only research starter'; }"
assert s.count(old) == 1
s = s.replace(old, "tier_allowlist() {\n  printf 'oneshot standard perf docs-only research starter'\n}")
open(p, "w", encoding="utf-8").write(s)
PY
  trust_fixture_policy "$P" "${TRUST_FIXTURE_MIN[@]}" 'allowed_steering = ["tier: oneshot"]'
  run --separate-stderr python3 -I -X utf8 "$lib/trust_policy.py" load "$P"
  [ "$status" -eq 3 ] || { echo "rc=$status err=$stderr" >&2; return 1; }
  [ "$stderr" = "cannot read the steering vocabulary from flags.sh (0 tier_allowlist lines, 1 model_token_allowlist lines)" ]
  [ "$output" = "" ]
  # positive control: an empty list never reads the vocabulary.
  trust_fixture_policy "$P" "${TRUST_FIXTURE_MIN[@]}" 'allowed_steering = []'
  run --separate-stderr python3 -I -X utf8 "$lib/trust_policy.py" load "$P"
  [ "$status" -eq 0 ]
}

@test "digest: explicit allowed_steering = [] and size_cap = 65536 leave it unchanged" {
  trust_fixture_policy "$P/a"
  trust_fixture_policy "$P/b" "${TRUST_FIXTURE_MIN[@]}" 'allowed_steering = []' 'size_cap = 65536'
  local a
  a="$(_digest "$P/a")"
  [[ "$a" == sha256:* ]]
  [ "$a" = "$(_digest "$P/b")" ]
}

@test "digest: allowed_steering order and duplicates do not move it" {
  trust_fixture_policy "$P/a" "${TRUST_FIXTURE_MIN[@]}" 'allowed_steering = ["tier: oneshot", "tier:check-fable"]'
  trust_fixture_policy "$P/b" "${TRUST_FIXTURE_MIN[@]}" 'allowed_steering = ["tier:check-fable", "tier: oneshot"]'
  trust_fixture_policy "$P/c" "${TRUST_FIXTURE_MIN[@]}" 'allowed_steering = ["tier: oneshot", "tier:check-fable", "tier: oneshot"]'
  local a
  a="$(_digest "$P/a")"
  [[ "$a" == sha256:* ]]
  [ "$a" = "$(_digest "$P/b")" ]
  [ "$a" = "$(_digest "$P/c")" ]
}

@test "steering: a wrong-typed value refuses" {
  local v
  for v in '"tier: oneshot"' 5; do
    trust_fixture_policy "$P" "${TRUST_FIXTURE_MIN[@]}" "allowed_steering = $v"
    _refuses "key 'allowed_steering' must be a list of strings"
    [ "$stderr" = "key 'allowed_steering' must be a list of strings" ]
  done
}
