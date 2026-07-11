#!/usr/bin/env bash
# scripts/born-red.sh — mechanism 1 (#362; design: Issue-333/designs/
# m1-born-red-mechanizer.md, normative). Opt-in born-red gate: run each NEW test
# in an ephemeral detached worktree at baseline_sha (the whole tests/ delta
# overlaid, product code at baseline) and then at HEAD; write an artifact; FLAG
# any test that is GREEN at baseline (vacuous / never-red). The operator's tree
# is NEVER mutated (read + cp-out only) — safe under --auto, safe on a mid-run
# kill (EXIT trap), so it never re-creates the #76 wipe and needs no #352 override.
#
# Knob off (default) → exit 0 no-op. Knob on + missing baseline / worktree
# failure / an empty name-filter match → die loud, NO artifact (#117/#314 class).
# The commit.sh gate (step 10) dies iff the latest artifact verdict is FLAGGED.
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=lib/paths.sh
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
# shellcheck source=lib/io.sh
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
# shellcheck source=lib/config.sh
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
# shellcheck source=lib/state.sh
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
# shellcheck source=lib/active.sh
. "$DEVAGENT_ROOT/scripts/lib/active.sh"

: "${DEVAGENT_GIT:=git}"

# Scrub inherited bats reentrancy env: born-red runs `bats` internally, and if it
# is itself invoked from within a bats run (its own test suite, or a future
# under-bats caller), leaked BATS_* vars make the inner bats try to run the OUTER
# run's requested test names ("unknown test name test_…"). Harmless in production
# (the workflow shell has none); load-bearing under test.
while IFS= read -r _v; do unset "$_v" 2>/dev/null || true; done \
  < <(compgen -v 2>/dev/null | grep '^BATS_' || true)

# ---- resolution (record-scope.sh precedent) --------------------------------
project="$(active_resolve_project "${1:-}" 2>/dev/null || true)"
[ -n "$project" ] || die "born-red: project required (no arg and no active project)"
config_is_project "$project" || die "born-red: unknown project '$project'"

# Opt-in: no-op unless born_red=true (the record-scope/commit_autostage precedent).
born_red="$(config_get_project_field "$project" born_red 2>/dev/null || echo false)"
[ "$born_red" = "true" ] || exit 0

issue_dir="$(issue_context_dir "$project" 2>/dev/null || true)"
[ -d "$issue_dir" ] || die "born-red: issue_dir not set or missing"
baseline="$(state_ctx_get "$project" baseline_sha 2>/dev/null || true)"
[ -n "$baseline" ] || die "born-red: baseline_sha not set (run branch first)"
source_dir="$(config_get_project_field "$project" source_dir)"
[ -d "$source_dir/.git" ] || [ -f "$source_dir/.git" ] \
  || die "born-red: source_dir is not a git repo: $source_dir"

cd "$source_dir"
"$DEVAGENT_GIT" rev-parse --verify "$baseline^{commit}" >/dev/null 2>&1 \
  || die "born-red: baseline_sha '$baseline' is not a resolvable commit"

# ---- helpers ----------------------------------------------------------------
_is_test_file() {   # bats or pytest test file under tests/ (case '*' spans '/')
  case "$1" in
    tests/*.bats)                      return 0 ;;
    tests/test_*.py|tests/*/test_*.py) return 0 ;;
    *) return 1 ;;
  esac
}
_framework() { case "$1" in *.bats) echo bats ;; *.py) echo pytest ;; esac; }
# Escape a bats test name into an ERE for `bats -f "^<name>$"`.
_ere_escape() { printf '%s' "$1" | sed 's/[][\\.^$*+?(){}|/]/\\&/g'; }

# ---- detect the NEW-test set vs the working tree ----------------------------
declare -a new_files=() mod_files=()
while IFS=$'\t' read -r status p1 p2; do
  [ -n "$status" ] || continue
  case "$status" in
    A*) _is_test_file "$p1" && new_files+=("$p1") ;;
    M*) _is_test_file "$p1" && mod_files+=("$p1") ;;
    R*) _is_test_file "$p2" && mod_files+=("$p2") ;;   # renamed → new path treated as modified
  esac
done < <("$DEVAGENT_GIT" diff --name-status -M "$baseline" -- tests/ 2>/dev/null || true)
while IFS= read -r p; do
  [ -n "$p" ] || continue
  _is_test_file "$p" && new_files+=("$p")
done < <("$DEVAGENT_GIT" ls-files --others --exclude-standard -- tests/ 2>/dev/null || true)

# Run list rows: "framework<TAB>file<TAB>name" (empty name ⇒ whole file).
declare -a units=()
for f in "${new_files[@]:-}"; do
  [ -n "$f" ] || continue
  units+=("$(_framework "$f")"$'\t'"$f"$'\t')
done
for f in "${mod_files[@]:-}"; do
  [ -n "$f" ] || continue
  if [ "$(_framework "$f")" = bats ]; then
    while IFS= read -r name; do
      [ -n "$name" ] && units+=("bats"$'\t'"$f"$'\t'"$name")
    done < <("$DEVAGENT_GIT" diff "$baseline" -- "$f" 2>/dev/null \
             | sed -n 's/^+[[:space:]]*@test[[:space:]]*"\(.*\)"[[:space:]]*{.*/\1/p')
  else
    while IFS= read -r name; do
      [ -n "$name" ] && units+=("pytest"$'\t'"$f"$'\t'"$name")
    done < <("$DEVAGENT_GIT" diff "$baseline" -- "$f" 2>/dev/null \
             | sed -n 's/^+[[:space:]]*def[[:space:]]\(test_[A-Za-z0-9_]*\).*/\1/p')
  fi
done

date_str="$(date +%F)"
mkdir -p "$issue_dir/analysis"
artifact="$issue_dir/analysis/${date_str}-born-red.txt"

if [ "${#units[@]}" -eq 0 ]; then
  { echo "born-red — $date_str"; echo "baseline: $baseline"; echo "new tests: 0";
    echo "verdict: NO-NEW-TESTS"; } > "$artifact"
  echo "born-red: no new tests detected → NO-NEW-TESTS" >&2
  exit 0
fi

# ---- allowlist: <file> :: <test> — <non-empty reason> -----------------------
declare -A allow=()
allow_file="$issue_dir/.devagent-born-red-allow"
if [ -f "$allow_file" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in \#*) continue ;; esac
    a_file="${line%% :: *}"; rest="${line#* :: }"
    case "$rest" in
      *" — "*)  a_name="${rest%% — *}";  a_reason="${rest#* — }" ;;
      *" -- "*) a_name="${rest%% -- *}"; a_reason="${rest#* -- }" ;;
      *) die "born-red: allowlist row missing ' — <reason>': $line" ;;
    esac
    [ -n "${a_reason// /}" ] || die "born-red: allowlist row has an empty reason: $line"
    allow["$a_file"$'\t'"$a_name"]="$a_reason"
  done < "$allow_file"
fi

# ---- ephemeral worktree at baseline (EXIT-trap safe) ------------------------
wt_parent="$(mktemp -d "${TMPDIR:-/tmp}/devagent-born-red.XXXXXX")"
wt="$wt_parent/wt"
rows_tmp="$(mktemp "${TMPDIR:-/tmp}/devagent-born-red-rows.XXXXXX")"
_cleanup() {
  "$DEVAGENT_GIT" worktree remove --force "$wt" >/dev/null 2>&1 || true
  "$DEVAGENT_GIT" worktree prune >/dev/null 2>&1 || true
  rm -rf "$wt_parent" 2>/dev/null || true
  rm -f "$rows_tmp" 2>/dev/null || true
}
trap _cleanup EXIT
"$DEVAGENT_GIT" worktree add --detach "$wt" "$baseline" >/dev/null 2>&1 \
  || die "born-red: git worktree add failed at $baseline"
# Overlay the WHOLE current tests/ (new tests + new helpers travel; product stays
# at baseline). cp-out only — the operator's tree is never mutated.
rm -rf "$wt/tests"
cp -a tests "$wt/tests"

# ---- run helpers ------------------------------------------------------------
_run_bats() {   # dir file name(optional) → TAP on stdout; die on empty -f match
  local dir="$1" file="$2" name="$3" out plan
  if [ -n "$name" ]; then
    out="$(cd "$dir" && bats --tap -f "^$(_ere_escape "$name")\$" "$file" 2>&1 || true)"
    plan="$(printf '%s\n' "$out" | sed -n 's/^1\.\.\([0-9]*\)$/\1/p' | head -1)"
    { [ -n "$plan" ] && [ "$plan" -gt 0 ]; } 2>/dev/null \
      || die "born-red: name filter matched ZERO tests: $file :: $name (bats exits 0 on an empty match)"
  else
    out="$(cd "$dir" && bats --tap "$file" 2>&1 || true)"
    # Whole-file runs must emit a TAP plan (`1..N`). Its absence means bats never
    # loaded the file (parse error / missing file) — the rows would silently
    # vanish into a PASS, so die. A present `1..0` (zero @test) is legitimate and
    # is handled as NO-NEW-TESTS after the run loop, not here.
    plan="$(printf '%s\n' "$out" | sed -n 's/^1\.\.\([0-9]*\)$/\1/p' | head -1)"
    [ -n "$plan" ] \
      || die "born-red: bats failed to load '$file' (no TAP plan emitted)"
  fi
  printf '%s\n' "$out"
}
_bats_rows() {  # stdin=TAP → "name<TAB>RED|GREEN"
  sed -n -E 's/^ok [0-9]+ (.*)$/\1\tGREEN/p; s/^not ok [0-9]+ (.*)$/\1\tRED/p'
}
_run_pytest() { # dir file name(optional) → RED|GREEN; die on empty selection
  local dir="$1" file="$2" name="$3" rc=0
  if [ -n "$name" ]; then
    ( cd "$dir" && python3 -m pytest -q -k "$name" "$file" >/dev/null 2>&1 ) || rc=$?
  else
    ( cd "$dir" && python3 -m pytest -q "$file" >/dev/null 2>&1 ) || rc=$?
  fi
  [ "$rc" -eq 5 ] && die "born-red: pytest selection matched ZERO tests: $file${name:+ -k $name}"
  [ "$rc" -eq 0 ] && echo GREEN || echo RED
}

flagged=0; allowed=0; total=0
_classify_row() {  # file name base head
  local file="$1" name="$2" base="$3" head="$4" tag reason
  total=$((total+1))
  if [ "$base" = RED ]; then
    tag="baseline=RED"
  else
    reason="${allow["$file"$'\t'"$name"]:-}"
    if [ -n "$reason" ]; then
      tag="baseline=GREEN-ALLOWED ($reason)"; allowed=$((allowed+1))
    else
      tag="baseline=GREEN"; flagged=$((flagged+1))
    fi
  fi
  printf '%s :: "%s" | %s | head=%s\n' "$file" "$name" "$tag" "$head" >> "$rows_tmp"
}

# ---- execute: baseline (worktree) then HEAD (source tree) -------------------
for u in "${units[@]}"; do
  IFS=$'\t' read -r fw file name <<<"$u"
  if [ "$fw" = bats ]; then
    base_tap="$(_run_bats "$wt" "$file" "$name")"
    head_tap="$(_run_bats "$source_dir" "$file" "$name")"
    declare -A base_res=() head_res=()
    while IFS=$'\t' read -r n r; do [ -n "$n" ] && base_res["$n"]="$r"; done < <(printf '%s\n' "$base_tap" | _bats_rows)
    while IFS=$'\t' read -r n r; do [ -n "$n" ] && head_res["$n"]="$r"; done < <(printf '%s\n' "$head_tap" | _bats_rows)
    for n in "${!base_res[@]}"; do
      _classify_row "$file" "$n" "${base_res[$n]}" "${head_res[$n]:-?}"
    done
    unset base_res head_res
  else
    base_r="$(_run_pytest "$wt" "$file" "$name")"
    head_r="$(_run_pytest "$source_dir" "$file" "$name")"
    _classify_row "$file" "${name:-<file>}" "$base_r" "$head_r"
  fi
done

# Every new file resolved to zero runnable tests (all bats whole-files emitted
# `1..0`; name-filter and pytest units either classify a row or die). That is a
# NO-NEW-TESTS run, not a PASS — mirror the pre-run zero-units guard's artifact.
if [ "$total" -eq 0 ]; then
  { echo "born-red — $date_str"; echo "baseline: $baseline"; echo "new tests: 0";
    echo "verdict: NO-NEW-TESTS"; } > "$artifact"
  echo "born-red: new test files contributed zero runnable tests → NO-NEW-TESTS" >&2
  exit 0
fi

# ---- verdict + artifact -----------------------------------------------------
if [ "$flagged" -gt 0 ]; then verdict="FLAGGED ($flagged green-at-baseline)"
elif [ "$allowed" -gt 0 ]; then verdict="PASS ($allowed allowed-green)"
else verdict="PASS"; fi

{
  echo "born-red — $date_str"
  echo "baseline: $baseline"
  echo "new tests: $total (flagged=$flagged, allowed-green=$allowed)"
  echo "---"
  sort "$rows_tmp"
  echo "---"
  echo "verdict: $verdict"
} > "$artifact"

if [ "$flagged" -gt 0 ]; then
  echo "born-red: $verdict — see $artifact" >&2
  exit 1
fi
echo "born-red: $verdict — see $artifact" >&2
exit 0
