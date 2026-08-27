#!/usr/bin/env bats
# #457: the PostToolUse pre-ship dirty-tree hook. After a ship invocation it surfaces
# UNTRACKED files (`^??`) in the issue worktree (exit 2 = PostToolUse feedback) — the
# class ship.sh's #148 gate EXCLUDES. Opt-in default-off, fail-open, fires once per
# identical untracked state, respects .gitignore.

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

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

@test "over-fire guard: ship.sh as an ARGUMENT (cat/git diff/vim) does NOT fire (#457 redmr)" {
  echo new > "$WT/newfile.txt"                 # untracked present, so only the match gates it
  local c
  for c in 'cat scripts/ship.sh' 'git diff scripts/ship.sh' 'vim scripts/ship.sh' \
           'shellcheck scripts/ship.sh' 'grep foo scripts/ship.sh' 'wc -l scripts/ship.sh'; do
    _feed "$(_j "$c")"
    [ "$status" -eq 0 ] || { echo "over-fired on inspection command: $c (status $status)" >&2; false; }
  done
  # but the real program forms DO fire (reset the per-worktree dedup marker between
  # them — they share an identical untracked state, which the dedup would otherwise
  # silence after the first):
  for c in 'bash scripts/ship.sh devagent' 'sh scripts/ship.sh' './scripts/ship.sh' 'scripts/ship.sh devagent'; do
    rm -f "$WT/.git/devagent-preship-nag"
    _feed "$(_j "$c")"
    [ "$status" -eq 2 ] || { echo "missed a real ship form: $c (status $status)" >&2; false; }
  done
}

@test "source_dir fallback: cwd not a git repo, but active project source_dir IS → fires (#457 redmr)" {
  # cwd is a plain (non-repo) dir; the active project's source_dir points at the worktree.
  printf '[defaults]\npreship_dirty_tree = true\n[project.acme]\nsource_dir = "%s"\n' "$WT" > "$DA/config.toml"
  printf 'active_issue = "Issue-7"\n' > "$DA/state/acme.toml"
  export DEVAGENT_ACTIVE_PROJECT=acme
  echo new > "$WT/newfile.txt"
  local nonrepo="$BATS_TEST_TMPDIR/plain"; mkdir -p "$nonrepo"
  _feed "$(_j 'bash scripts/ship.sh acme' "$nonrepo")"
  [ "$status" -eq 2 ]
  [[ "$output" == *"newfile.txt"* ]]
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
