#!/usr/bin/env bats

load 'helpers'

setup() {
  source "${REPO_ROOT}/scripts/capture/lib/draft.sh"
}

@test "draft_h1: prints the first '# ' line with the prefix stripped (#597)" {
  f="${BATS_TEST_TMPDIR}/d.md"
  printf 'preamble\n#  Corn planting\n\n# Second H1\n' > "${f}"
  [ "$(devagent_draft_h1 "${f}")" = "Corn planting" ]
}

@test "draft_h1: no '# ' heading prints nothing, rc 0 (#597)" {
  f="${BATS_TEST_TMPDIR}/d.md"
  printf 'Corn planting\n=====\n## Not an H1\n' > "${f}"
  run devagent_draft_h1 "${f}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "draft_h1: a missing file fails non-zero (#597)" {
  run devagent_draft_h1 "${BATS_TEST_TMPDIR}/absent.md"
  [ "$status" -eq 2 ]                            # awk's rc for an unreadable input
}
