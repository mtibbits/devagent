#!/usr/bin/env bats

load 'helpers'

setup() {
  source "${REPO_ROOT}/scripts/capture/lib/hash.sh"
}

@test "hash: same content produces same hash" {
  h1="$(devagent_hash_text "hello world")"
  h2="$(devagent_hash_text "hello world")"
  [ "${h1}" = "${h2}" ]
  [ -n "${h1}" ]
}

@test "hash: different content produces different hash" {
  h1="$(devagent_hash_text "hello world")"
  h2="$(devagent_hash_text "hello world!")"
  [ "${h1}" != "${h2}" ]
}

@test "hash: insensitive to leading/trailing whitespace and case" {
  h1="$(devagent_hash_text "Hello World")"
  h2="$(devagent_hash_text "  hello world  ")"
  h3="$(devagent_hash_text $'\nHELLO\tWORLD\n')"
  [ "${h1}" = "${h2}" ]
  [ "${h2}" = "${h3}" ]
}

@test "hash: 12 hex chars" {
  h="$(devagent_hash_text "anything")"
  [[ "${h}" =~ ^[0-9a-f]{12}$ ]]
}
