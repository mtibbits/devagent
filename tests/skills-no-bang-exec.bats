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
