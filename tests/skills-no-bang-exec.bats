#!/usr/bin/env bats
# #534: pin the invariant PR #521's command→skill conversion relies on — no
# user-invocable skill carries a `!` bang-exec line. Slash-COMMANDS preprocess a
# leading `!` line into an auto-executed shell command (command-expansion, before
# the model runs); the ship/next/capture skills deliberately carry NONE, so the
# model runs the script through the Bash TOOL instead — which is what
# hooks/preship-dirty-tree.sh + spec §8 (~921-933) assert and observe. A `!` line
# creeping back into a user-invocable skill would silently reintroduce the
# deterministic auto-exec path the conversion removed.
# #596 adds the POSITIVE counterpart for commands/*.md (@test 7-10; see below).
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
# commands/*.md are NOT clean, and since #596 that is PINNED, not merely described:
# analyze, branch, cleanup, commit, mergetoall and sync each carry exactly one
# bang-exec line, at column 0 — that IS the command-side auto-exec path this
# invariant exists to keep out of skills. @test 7 pins the exact six-name set (it
# alone catches a stray seventh carrier), @test 8 the per-file count of one, @test 9
# the column-0 convention, and @test 10 is their anti-vacuity fixture. Still NOT
# pinned here: the grammar itself (the STATED BLIND SPOT above applies equally to the
# positive pin), and whether the harness would auto-execute a bang line that is
# INDENTED or sits inside a ``` FENCE — @test 9 pins the shape this repo ships, and a
# fenced line leaves all four @tests green.
# agents/*.md carry zero, but are a different invocation surface and are not pinned.
#
# COST OF ADDING A SKILL, so the next person is not surprised: adding, removing or
# renaming ANY skill reddens @test 4 — that is the intended forcing function. Adding
# a USER-INVOCABLE one also reddens @test 1 here and, in tests/cmd_wrappers.bats,
# the `capture next ship` set pin and the derived-totals test, which names every
# doc home whose "<N> slash commands" claim no longer matches the tree (README,
# CHANGELOG, both .claude-plugin manifests, the design spec, docs-site/index.md).
# Since #579 the totals are derived, so the update is the doc homes it names, not
# the guard itself.
# Adding a COMMAND that carries a bang-exec line reddens @test 7 (#596) — the
# six-name set is a literal there. Adding a command WITHOUT one reddens nothing in
# this file; tests/cmd_wrappers.bats derives the command total from the tree (#579).

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

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

# #596: the COLUMN-0 form of the same shape, DERIVED from `_bang_exec_re` (strip its
# leading-whitespace allowance, re-anchor) so the two cannot drift apart — a later
# grammar change to `_bang_exec_re` carries into this one (Issue-585: a re-spelled
# matcher tests a copy). `_bang_exec_re` is indent-TOLERANT, which is fail-closed for
# #550's negative guard (over-matching is safe when hunting offenders) but fail-OPEN
# for #596's positive pin: an indented bang line would still satisfy "this command
# carries one". This is a CONVENTION pin on the shape the repo ships and makes NO
# claim about whether the harness would auto-execute an indented line (the STATED
# BLIND SPOT above). The fixture @test pins its value and its behaviour.
_bang_exec_col0_re="^${_bang_exec_re#"^[[:space:]]*"}"

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

# The ONE home of "how many lines of <dir>/<name><suffix> match regex $3" — #550's
# skills scan and #596's command pins both go through it (Issue-565: one home per
# question). The names are the denominator the caller already counted (#151: count
# what the assertions actually run against). Prints "<name>:<count>" per name,
# sorted, space-separated. rc-precise (#337/#314): grep -c exits 0 on a match, 1 on
# a CLEAN no-match, and >=2 on ERROR; the error rung returns 2 rather than being
# read as "found nothing", so an unreadable subject reddens instead of passing. A
# missing subject file is also a hard 2 — a shrunken glob must never read as clean.
_bang_counts() {             # $1 = dir; $2 = path suffix; $3 = regex; $4.. = names
  local dir="$1" suffix="$2" re="$3"; shift 3
  local name f n rc
  local -a out=()
  for name in "$@"; do
    f="$dir/$name$suffix"
    [ -f "$f" ] || { echo "missing subject file: $f" >&2; return 2; }
    rc=0; n="$(grep -cE "$re" "$f")" || rc=$?
    [ "$rc" -le 1 ] || { echo "grep failed (rc=$rc) on $f" >&2; return 2; }
    out+=("$name:$n")
  done
  [ ${#out[@]} -eq 0 ] && return 0
  printf '%s\n' "${out[@]}" | sort | tr '\n' ' ' | sed 's/ $//'
}

# Names (of those given) whose file carries at least one `_bang_exec_re` line.
# Sorted, space-separated, empty when clean; _bang_counts's rc 2 propagates.
_bang_carriers() {           # $1 = dir; $2 = path suffix; $3.. = names
  local counts pair
  local -a hit=()
  counts="$(_bang_counts "$1" "$2" "$_bang_exec_re" "${@:3}")" || return $?
  for pair in $counts; do
    if [ "${pair##*:}" -gt 0 ]; then hit+=("${pair%:*}"); fi
  done
  [ ${#hit[@]} -eq 0 ] && return 0
  printf '%s\n' "${hit[@]}" | sort | tr '\n' ' ' | sed 's/ $//'
}

# #550: the skills whose SKILL.md carries a bang-exec line.
_bang_offenders() {          # $1 = skills dir; $2.. = skill names to scan
  _bang_carriers "$1" /SKILL.md "${@:2}"
}

# #596: sorted, space-separated basenames (sans .md) of every commands/*.md.
# Dir-parameterized so the anti-vacuity @test runs it against a fixture tree.
# shellcheck disable=SC2120  # args ARE passed by the fixture @test; the real
# @tests call it argless via the ${1:-} default. Same disposition as _all_skills.
_all_commands() {
  local dir="${1:-$REPO/commands}" f
  local -a all=()
  for f in "$dir"/*.md; do
    [ -e "$f" ] || continue
    all+=("$(basename "$f" .md)")
  done
  [ ${#all[@]} -eq 0 ] && return 0
  printf '%s\n' "${all[@]}" | sort | tr '\n' ' ' | sed 's/ $//'
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

@test "exactly six commands carry a bang-exec line (positive pin, #596)" {
  run type -t _bang_carriers
  [ "$status" -eq 0 ]
  [ "$output" = "function" ]

  # denominator FIRST, from the same glob the scan runs over (#151)
  local -a cmds=()
  read -r -a cmds <<< "$(_all_commands)"
  [ "${#cmds[@]}" -gt 0 ] || { echo "commands glob enumerated nothing" >&2; return 1; }

  run _bang_carriers "$REPO/commands" .md "${cmds[@]}"
  [ "$status" -eq 0 ]
  # exact SET. Only this @test catches a stray SEVENTH carrier; a DROPPED carrier
  # also reddens @test 8, which names the six (belt-and-braces, Issue-550).
  [ "$output" = "analyze branch cleanup commit mergetoall sync" ] || {
    echo "bang-exec carrier set drifted: got ($output)" >&2; return 1; }
}

@test "each of the six carries exactly ONE bang-exec line (#596)" {
  run type -t _bang_counts
  [ "$status" -eq 0 ]
  [ "$output" = "function" ]

  local -a six=(analyze branch cleanup commit mergetoall sync)
  run _bang_counts "$REPO/commands" .md "$_bang_exec_re" "${six[@]}"
  [ "$status" -eq 0 ]
  [ "$output" = "analyze:1 branch:1 cleanup:1 commit:1 mergetoall:1 sync:1" ] || {
    echo "per-command bang-exec count drifted: $output" >&2; return 1; }
}

@test "all six bang-exec lines sit at column 0 (convention pin, #596)" {
  # Separate @test, not a third assertion in @test 8: a multi-assertion guard
  # reddens only at its FIRST failing assert (Issue-123), and the mutation matrix
  # needs this leg to redden independently of the set and count legs.
  local -a six=(analyze branch cleanup commit mergetoall sync)
  run _bang_counts "$REPO/commands" .md "$_bang_exec_col0_re" "${six[@]}"
  [ "$status" -eq 0 ]
  [ "$output" = "analyze:1 branch:1 cleanup:1 commit:1 mergetoall:1 sync:1" ] || {
    echo "a bang-exec line is no longer at column 0: $output" >&2; return 1; }
}

@test "self-test: the command scan distinguishes col-0, indented, image and clean (#596)" {
  # Synthetic tree — never mutate the real one. Pins how the two regexes relate
  # and carries the controls each must NOT match (Issue-585/volk Issue-Fork-195).
  # The derived column-0 regex has a pinned VALUE: a grammar change to
  # _bang_exec_re reddens here, so whoever makes it re-checks @test 9's premise.
  [ "$_bang_exec_col0_re" = '^![^[]' ] || {
    echo "derived column-0 regex changed: $_bang_exec_col0_re" >&2; return 1; }

  local d="$BATS_TEST_TMPDIR/commands"
  mkdir -p "$d"
  printf -- 'prose\n!`bash /tmp/x.sh`\n'   > "$d/col0.md"
  printf -- 'prose\n  !`bash /tmp/x.sh`\n' > "$d/indented.md"
  printf -- 'prose\n![alt](img.png)\n'     > "$d/image.md"
  printf -- 'prose\nnothing here\n'        > "$d/clean.md"

  run _all_commands "$d"
  [ "$status" -eq 0 ]
  [ "$output" = "clean col0 image indented" ]

  # the indent-tolerant regex matches BOTH col0 and indented, and neither control
  run _bang_counts "$d" .md "$_bang_exec_re" clean col0 image indented
  [ "$status" -eq 0 ]
  [ "$output" = "clean:0 col0:1 image:0 indented:1" ]

  # the column-0 regex matches ONLY col0 — this is what makes @test 9 load-bearing
  run _bang_counts "$d" .md "$_bang_exec_col0_re" clean col0 image indented
  [ "$status" -eq 0 ]
  [ "$output" = "clean:0 col0:1 image:0 indented:0" ]

  # @test 7's carrier filter names exactly the two bang files, neither control
  run _bang_carriers "$d" .md clean col0 image indented
  [ "$status" -eq 0 ]
  [ "$output" = "col0 indented" ]

  # a missing subject is a hard 2, never a silent clean read (#337)
  run _bang_counts "$d" .md "$_bang_exec_re" nosuchcommand
  [ "$status" -eq 2 ]
}
