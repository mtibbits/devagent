# Implementation Plan — Issue-900

## Goal

Collapse state.sh, config.sh, and template.sh into one `lib/core.sh`, migrate all
95 call sites, add a `[core]` config section (9 keys), and ship three new
subcommands (core-doctor, core-migrate, core-export).

## Approach

Write `lib/core.sh` merging the three layers, then sweep every command and script
to the new API, then add the config section and the three subcommands with tests.

## Tasks

- [ ] Author `lib/core.sh` (~600 LOC merging three layers)
- [ ] Migrate 55 command files to the new entry points
- [ ] Migrate 40 scripts to the new entry points
- [ ] Add `[core]` section with 9 keys to config.toml + spec
- [ ] Implement core-doctor, core-migrate, core-export (~400 LOC + tests)
- [ ] Update all affected bats fixtures

## Validation

Full suite green after the migration.

## Out of scope

Nothing — this is the whole refactor.
