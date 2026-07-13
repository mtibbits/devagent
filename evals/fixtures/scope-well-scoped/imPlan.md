# Implementation Plan — Issue-901

## Goal

Add one read-only `analyze: <family>` line per project to the `/devagent:doctor`
report so the operator can confirm the resolved step-11 family without reading
config.toml.

## Approach

In `scripts/doctor.sh`, after the existing per-project config-validity block,
read the already-resolved `analyze` value (config.sh getter, no new parse) and
echo one line. No writes, no new config keys.

## Tasks

- [ ] Add the `analyze: <family>` echo to the per-project loop in doctor.sh (~4 LOC)
- [ ] Add one bats case in `tests/doctor.bats` asserting the line for a fixture project
- [ ] Fall back to `analyze: (unset)` when the key is absent (no die)

## Validation

`tests/doctor.bats` green; the new case mutation-proven RED against the unpatched
doctor.sh. `git diff` touches only doctor.sh + doctor.bats.

## Out of scope

- Changing what `analyze` resolves to (report only).
- Any config write or new key.
