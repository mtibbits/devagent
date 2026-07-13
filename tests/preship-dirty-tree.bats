#!/usr/bin/env bats
# #457: the PostToolUse pre-ship dirty-tree hook. After a ship invocation it surfaces
# UNTRACKED files (`^??`) in the issue worktree (exit 2 = PostToolUse feedback) — the
# class ship.sh's #148 gate EXCLUDES. Opt-in default-off, fail-open, fires once per
# identical untracked state, respects .gitignore.

REPO="${BATS_TEST_DIRNAME}/.."
HOOK="$REPO/hooks/preship-dirty-tree.sh"

setup() {
  DA="$BATS_TEST_TMPDIR/da"; mkdir -p "$DA/state"
  export DA_HOME="$DA"
  printf '[defaults]\npreship_dirty_tree = true\n' > "$DA/config.toml"
  unset DEVAGENT_PRESHIP_DIRTY_TREE_OVERRIDE
  WT="$BATS_TEST_TMPDIR/repo"; mkdir -p "$WT"
  git -C "$WT" init -q
  echo base > "$WT/f"; printf 'scratch/\n*.tmp\n' > "$WT/.gitignore"
  git -C "$WT" add f .gitignore
  git -C "$WT" -c user.email=t@t -c user.name=t commit -qm base
}
_j()  { printf '{"tool_input":{"command":%s},"cwd":"%s"}' \
          "$(printf '%s' "$1" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')" "${2:-$WT}"; }
_ship() { _j 'bash scripts/ship.sh devagent' "${1:-$WT}"; }
_feed() { run bash -c 'printf "%s" "$1" | bash "$2"' _ "$1" "$HOOK"; }

@test "untracked file in worktree at ship → SURFACED once (exit 2, names the file) (#457)" {
  echo new > "$WT/newfile.txt"
  _feed "$(_ship)"
  [ "$status" -eq 2 ]
  [[ "$output" == *"newfile.txt"* ]]
}

@test "gitignored paths (build/scratch) are NEVER flagged (#457)" {
  mkdir -p "$WT/scratch"; echo x > "$WT/scratch/z"; echo y > "$WT/a.tmp"
  _feed "$(_ship)"
  [ "$status" -eq 0 ]
}

@test "fires at most once per identical state — second ship is SILENT (#457)" {
  echo new > "$WT/newfile.txt"
  _feed "$(_ship)"; [ "$status" -eq 2 ]
  _feed "$(_ship)"; [ "$status" -eq 0 ]   # deduped
}

@test "a CHANGED untracked set re-surfaces (dedup is state-keyed, not one-shot) (#457)" {
  echo new > "$WT/newfile.txt"
  _feed "$(_ship)"; [ "$status" -eq 2 ]
  echo other > "$WT/second.txt"            # untracked set changed
  _feed "$(_ship)"; [ "$status" -eq 2 ]
}

@test "a TRACKED-modified file (not untracked) is NOT flagged — the #148 boundary (#457)" {
  echo change >> "$WT/f"                    # modified tracked, no untracked
  _feed "$(_ship)"
  [ "$status" -eq 0 ]
}

@test "a non-ship Bash command → exit 0 (does not fire) (#457)" {
  echo new > "$WT/newfile.txt"
  _feed "$(_j 'git status --porcelain')"
  [ "$status" -eq 0 ]
}

@test "opt-in default-off + override + no-worktree fail-open → exit 0 (#457)" {
  echo new > "$WT/newfile.txt"
  printf '[defaults]\n' > "$DA/config.toml"                 # gate off
  _feed "$(_ship)"; [ "$status" -eq 0 ]
  printf '[defaults]\npreship_dirty_tree = true\n' > "$DA/config.toml"
  export DEVAGENT_PRESHIP_DIRTY_TREE_OVERRIDE=1             # override
  _feed "$(_ship)"; [ "$status" -eq 0 ]
  unset DEVAGENT_PRESHIP_DIRTY_TREE_OVERRIDE
  _feed "$(_ship "$BATS_TEST_TMPDIR/not-a-repo")"          # cwd not a git repo, no active project
  [ "$status" -eq 0 ]
}
