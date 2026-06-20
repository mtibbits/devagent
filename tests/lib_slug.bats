#!/usr/bin/env bats

load 'helpers'

setup() {
  source "${REPO_ROOT}/scripts/capture/lib/slug.sh"
  freeze_date 2026-05-19
}

@test "slug: simple title" {
  run devagent_slug "Corn planting"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-05-19-corn-planting" ]
}

@test "slug: collapses runs of non-alnum" {
  run devagent_slug "Fix --- the !!! kernel  bug"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-05-19-fix-the-kernel-bug" ]
}

@test "slug: strips leading/trailing dashes" {
  run devagent_slug "---hello world---"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-05-19-hello-world" ]
}

@test "slug: lowercases" {
  run devagent_slug "FOO Bar BAZ"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-05-19-foo-bar-baz" ]
}

@test "slug: truncates excessively long titles to 60 chars after the date" {
  long="$(printf 'word %.0s' {1..40})"
  run devagent_slug "${long}"
  [ "$status" -eq 0 ]
  [ "${#output}" -le 71 ]
}

@test "slug: empty title fails with explanatory message" {
  run devagent_slug ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty title"* ]]
}

@test "slug: title that becomes empty after sanitization fails" {
  run devagent_slug "!!! --- ???"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty"* ]]
}

@test "slug: an optional suffix survives the 60-char cap (#252)" {
  # The #108 collision retry's disambiguator must not be sliced off by the cap.
  long="$(printf 'word %.0s' {1..40})"   # kebabs to far more than 60 chars
  run devagent_slug "${long}" "ab12cd"
  [ "$status" -eq 0 ]
  [[ "$output" == *-ab12cd ]]            # suffix present despite the cap
  kebab="${output#2026-05-19-}"
  [ "${#kebab}" -le 60 ]                 # total kebab still within the cap
}

@test "slug: a suffix on a short title is appended verbatim (#252)" {
  run devagent_slug "Corn planting" "ab12cd"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-05-19-corn-planting-ab12cd" ]
}

@test "slug: no/empty suffix leaves the slug byte-identical (#252 back-compat)" {
  run devagent_slug "Corn planting"
  [ "$output" = "2026-05-19-corn-planting" ]
  run devagent_slug "Corn planting" ""
  [ "$output" = "2026-05-19-corn-planting" ]
}
