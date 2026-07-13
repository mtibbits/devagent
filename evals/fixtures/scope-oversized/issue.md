# example/repo#900 — unify the state, config, and template layers into one module

- State: open
- Author: @someone
- Labels:

---

## Scope
The `lib/state.sh`, `lib/config.sh`, and `lib/template.sh` layers have grown
overlapping TOML-reading helpers. Merge all three into a single `lib/core.sh`,
rewrite every caller across the 55 command files and 40 scripts to the new
entry points, add a `[core]` config section with 9 new keys, and introduce
three brand-new subcommands (`core-doctor`, `core-migrate`, `core-export`).

## Acceptance criteria
- [ ] `lib/core.sh` replaces state.sh + config.sh + template.sh
- [ ] all 95 call sites migrated
- [ ] 9 new `[core]` keys documented in the spec
- [ ] 3 new subcommands with bats coverage
