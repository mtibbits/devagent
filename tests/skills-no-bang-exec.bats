#!/usr/bin/env bats
# #534: pin the invariant PR #521's command→skill conversion relies on — no
# user-invocable skill carries a `!` bang-exec line. Slash-COMMANDS preprocess a
# leading `!` line into an auto-executed shell command (command-expansion, before
# the model runs); the ship/next/capture skills deliberately carry NONE, so the
# model runs the script through the Bash TOOL instead — which is what
# hooks/preship-dirty-tree.sh + spec §8 (~921-933) assert and observe. A `!` line
# creeping back into a user-invocable skill would silently reintroduce the
# deterministic auto-exec path the conversion removed.
#
# Glob-drop guard (Issue-439): the subject set is enumerated by a glob; if a
# rename/conversion empties it, "0 skills, 0 bang lines" would pass vacuously.
# So @test 1 asserts the exact SET + COUNT before @test 2 checks bang lines
# (Issue-337: a presence-canary asserts a precise count, never `-ne 0`).
#
# #550 WIDENS the canary to ALL skills/*/SKILL.md, including the 14
# `user-invocable: false` core-* skills. Those are invoked via the Skill tool by the
# workflow chain, so a bang-exec line in one would auto-exec just the same, and
# would be unobservable to both the `--auto` chain and hooks/preship-dirty-tree.sh.
# The widened trio (@test 4-6) is ADDITIVE: @test 1-3 remain the narrower #521
# invariant and its exact-set guard on the user-invocable subset. @test 6 is the
# standing proof the widening is load-bearing — its fixture's only offender is a
# hidden (user-invocable:false) skill, which the pre-#550 subject list does not
# contain.
#
# STATED BLIND SPOT (Issue-558 — a checker's green overclaims unless its blind-spot
# SHAPE is written into the checker): `_bang_exec_re` pins exactly ONE spelling of a
# vendor grammar this repo does not control. A future command-expansion form that is
# not "leading `!` not followed by `[`" is invisible here; a bare `!` alone on a line
# and the markdown-image `![` form are excluded BY DESIGN. Broadening the grammar is
# deliberately out of scope for #550 (see the issue's future-enhancements file).
#
# DO NOT ILLUSTRATE THIS PATTERN INSIDE ANY SKILL.md (Issue-561): a comment or
# example that spells a leading-bang line inside a skill file self-trips the guard it
# is explaining. This .bats file is not a scan subject, which is why the literal is
# safe here.
#
# commands/*.md are deliberately OUT of scope and are NOT clean: analyze, branch,
# cleanup, commit, mergetoall and sync each carry exactly one bang-exec line — that
# IS the command-side auto-exec path this invariant exists to keep out of skills.
# agents/*.md carry zero, but are a different invocation surface and are not pinned.
#
# COST OF ADDING A SKILL, so the next person is not surprised: adding, removing or
# renaming ANY skill reddens @test 4 — that is the intended forcing function. Adding
# a USER-INVOCABLE one also reddens @test 1 here and, in tests/cmd_wrappers.bats,
# the `capture next ship` set pin and the `-eq 3` / `n + s -eq 58` counts — and that
# file pins the "58 slash commands" literal in SIX doc homes (README, CHANGELOG,
# both .claude-plugin manifests, the design spec, docs-site/index.md). Budget
# roughly an eight-site update, not a one-line one.

REPO="${BATS_TEST_DIRNAME}/.."

# A user-invocable skill = a SKILL.md whose FRONTMATTER `user-invocable:` is absent
# or not in {false,False,FALSE}. Frontmatter-scoped, CR-tolerant, mawk-safe — the
# #526 YAML-truth classifier (agrees with test_frontmatter_yaml.py). Classifier body
# reused (wrapper adapted) from tests/cmd_wrappers.bats so this guard does NOT repeat the
# whole-file-grep bug
# #526 fixed (a body-prose `user-invocable: false` must not misclassify). Returns a
# sorted, space-separated set. (A shared helper is the standing #526 follow-up.)
_user_invocable_skills() {
  local dir="${1:-$REPO/skills}" f name val
  local -a uinv=()
  for f in "$dir"/*/SKILL.md; do
    [ -e "$f" ] || continue
    name="$(basename "$(dirname "$f")")"
    val="$(awk '
      /^---[ \t\r]*$/ { c++; if (c >= 2) exit; next }
      c == 1 && /^user-invocable:[ \t]/ {
        sub(/\r$/, ""); sub(/^user-invocable:[ \t]*/, ""); sub(/[ \t]*#.*/, ""); sub(/[ \t]+$/, "")
        print; exit
      }
    ' "$f")"
    case "$val" in
      false|False|FALSE) ;;
      *) uinv+=("$name") ;;
    esac
  done
  [ ${#uinv[@]} -eq 0 ] && return 0
  printf '%s\n' "${uinv[@]}" | sort | tr '\n' ' ' | sed 's/ $//'
}

# A bang-exec line = a line whose first non-space char is `!` and is NOT a
# markdown image (`![`). Matches `!cmd` and the `` !`cmd` `` backtick form.
_bang_exec_re='^[[:space:]]*![^[]'

# #550: the FULL skill set — directory names of every skills/*/SKILL.md, sorted,
# space-separated. This is NOT a second classifier: it reads no frontmatter, and
# it answers a different question ("which skills exist") from the one
# _user_invocable_skills answers ("which of those are user-invocable"). Same glob
# on purpose. The primary drift guard is the PAIR of exact-set literals (@test 1 and
# @test 4); @test 4's subset loop is belt-and-braces on top of them. Dir-parameterized so the
# anti-vacuity proof can run it against a synthetic fixture tree instead of the
# real one. (skills/.gitkeep is a tracked file directly under skills/ and is
# correctly never matched by */SKILL.md.)
# shellcheck disable=SC2120  # args ARE passed by the anti-vacuity @test (fixture
# tree); the floor and scan @tests call it argless via the ${1:-} default. Same
# false positive, same disposition, as tests/cmd_wrappers.bats's on the classifier.
_all_skills() {
  local dir="${1:-$REPO/skills}" f
  local -a all=()
  for f in "$dir"/*/SKILL.md; do
    [ -e "$f" ] || continue
    all+=("$(basename "$(dirname "$f")")")
  done
  [ ${#all[@]} -eq 0 ] && return 0
  printf '%s\n' "${all[@]}" | sort | tr '\n' ' ' | sed 's/ $//'
}

# #550: names of the skills — from the NAME LIST the caller passes in, which is
# the denominator the caller already counted (#151: count what the assertions
# actually run against) — whose SKILL.md carries a bang-exec line. Sorted,
# space-separated, empty when clean. rc-precise (#337/#314): grep -c exits 0 on a
# match, 1 on a CLEAN no-match, and >=2 on ERROR; the error rung returns 2 rather
# than being read as "found nothing", so an unreadable subject reddens instead of
# passing. A missing subject file is also a hard 2 — a shrunken glob must never
# read as clean.
_bang_offenders() {          # $1 = skills dir; $2.. = skill names to scan
  local dir="$1"; shift
  local name f n rc
  local -a bad=()
  for name in "$@"; do
    f="$dir/$name/SKILL.md"
    [ -f "$f" ] || { echo "missing subject file: $f" >&2; return 2; }
    rc=0; n="$(grep -cE "$_bang_exec_re" "$f")" || rc=$?
    [ "$rc" -le 1 ] || { echo "grep failed (rc=$rc) on $f" >&2; return 2; }
    [ "$n" -gt 0 ] && bad+=("$name")
  done
  [ ${#bad[@]} -eq 0 ] && return 0
  printf '%s\n' "${bad[@]}" | sort | tr '\n' ' ' | sed 's/ $//'
}

@test "exactly the three known user-invocable skills (glob-drop + unexpected-addition guard, #439)" {
  run _user_invocable_skills
  [ "$status" -eq 0 ]
  # exact set — strictly stronger than a bare count; reddens on drop OR addition
  [ "$output" = "capture next ship" ]
  # explicit count floor so an emptied glob can never pass @test 2 vacuously
  [ "$(printf '%s' "$output" | wc -w)" -eq 3 ]
}

@test "no user-invocable skill carries a bang-exec line (#521 conversion invariant)" {
  local total=0
  for skill in $(_user_invocable_skills); do
    local f="$REPO/skills/$skill/SKILL.md"
    run grep -cE "$_bang_exec_re" "$f"
    # grep -c prints the count and exits 1 on zero matches; assert the count is 0
    [ "$output" -eq 0 ] || { echo "bang-exec line found in skills/$skill/SKILL.md"; false; }
    total=$((total + 1))
  done
  # ran over a non-empty subject set (pairs with @test 1's count)
  [ "$total" -eq 3 ]
}

@test "self-test: the bang-exec regex actually matches a planted bang line (anti-vacuity, #425)" {
  # Prove @test 2's regex is live by matching a synthetic fixture — never mutate
  # the real tree. A regex that matched nothing would pass @test 2 vacuously.
  local tmp; tmp="$(mktemp)"
  printf -- '---\nname: x\n---\nsome prose\n!`bash /tmp/x.sh`\n' > "$tmp"
  run grep -cE "$_bang_exec_re" "$tmp"
  [ "$output" -eq 1 ]
  rm -f "$tmp"
}

@test "exactly the 17 known skills exist (full-set glob-drop + unexpected-addition floor, #439/#337/#550)" {
  run _all_skills
  [ "$status" -eq 0 ]
  # exact set over the FULL skill set — strictly stronger than a bare count at the
  # same churn cost: a rename or a 1-for-1 swap keeps the count at 17 and is
  # invisible to a count, and a mismatch NAMES the delta instead of printing 16!=17
  [ "$output" = "capture core-capture core-document-actual-work core-draft-mr core-impact core-improve core-lessons-learned core-preship core-prune core-reap core-redissue core-redmr core-scaffold core-scope core-tighten next ship" ]
  # explicit count floor so an emptied glob can never pass @test 5 vacuously, and
  # so a future weakening of the set assert still leaves a live floor
  [ "$(printf '%s' "$output" | wc -w)" -eq 17 ]
  # Belt-and-braces: every user-invocable name is in the full set. The exact-set
  # literal above (paired with @test 1's) is what actually catches drift — this loop
  # is vacuous on an empty classifier result and, when non-empty, can only fire in
  # cases @test 1 already reddens. Kept because it is cheap and names the offender.
  local u
  for u in $(_user_invocable_skills); do
    [[ " $output " == *" $u "* ]] || { echo "enumerator drift: $u not in the full skill set" >&2; return 1; }
  done
}

@test "no skill of ANY visibility carries a bang-exec line (core-* included, #550)" {
  # #572: prove the helper EXISTS first — bats `run` on a missing function yields
  # status 127 with EMPTY output, which would satisfy the "no offenders" assertion
  # below vacuously.
  run type -t _bang_offenders
  [ "$status" -eq 0 ]
  [ "$output" = "function" ]

  # the denominator is counted BEFORE the scan and is the SAME list the scan runs
  # over (#151: count what the assertions actually run against, not a parallel glob)
  local -a set_=()
  read -r -a set_ <<< "$(_all_skills)"
  [ "${#set_[@]}" -eq 17 ]

  run _bang_offenders "$REPO/skills" "${set_[@]}"
  # status 0 = clean scan; 2 = grep error or a missing subject (the type -t check
  # above has already ruled out the missing-function 127)
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "bang-exec line(s) found in skills: $output" >&2; return 1; }
}

@test "self-test: the all-skills scan names a planted offender in a HIDDEN skill (anti-vacuity, #425/#151/#550)" {
  # A synthetic skills tree — never mutate the real one. The ONLY offender is a
  # user-invocable:false skill, which is exactly the hole #550 closes.
  local d="$BATS_TEST_TMPDIR/skills"
  mkdir -p "$d/core-clean" "$d/core-bad" "$d/vis-clean"
  printf -- '---\nname: core-clean\nuser-invocable: false\n---\nprose\n' > "$d/core-clean/SKILL.md"
  printf -- '---\nname: core-bad\nuser-invocable: false\n---\nprose\n!`bash /tmp/x.sh`\n' > "$d/core-bad/SKILL.md"
  printf -- '---\nname: vis-clean\n---\nprose\n' > "$d/vis-clean/SKILL.md"

  # the fixture is enumerated through the SAME helper the real guard uses
  run _all_skills "$d"
  [ "$status" -eq 0 ]
  [ "$output" = "core-bad core-clean vis-clean" ]

  # THE #550 PREMISE, made executable: the pre-#550 user-invocable-scoped subject
  # list does NOT contain the offender, so the narrower guard passes this fixture
  # vacuously. This assertion is what proves the widening is load-bearing.
  run _user_invocable_skills "$d"
  [ "$status" -eq 0 ]
  [ "$output" = "vis-clean" ]

  # the widened scan DOES name it (positive leg), and does not name the two clean
  # skills (negative leg — a rewrite must not turn fail-closed into fail-open)
  local -a s=(core-bad core-clean vis-clean)
  run _bang_offenders "$d" "${s[@]}"
  [ "$status" -eq 0 ]
  [ "$output" = "core-bad" ]
}
