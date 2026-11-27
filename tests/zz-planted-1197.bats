#!/usr/bin/env bats
# bats file_tags=gitbash
# #1197 run 2 (throwaway, reverted before merge): a planted failing tagged file. It
# passes on the Linux shards and fails only under Git Bash, so the Git Bash shard
# holding it fails and the `Git Bash tagged files` gate must report failure.

load 'lib/bats-helpers'

@test "planted failure (#1197): fails only under Git Bash" { [ "$(uname -s)" = Linux ]; }
