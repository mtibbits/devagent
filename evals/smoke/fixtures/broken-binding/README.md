# Broken-binding fixture (#530)

A deliberately-degraded `preship-verifier.md` — `disallowedTools` stripped and
the first system-prompt sentence mangled. This is NOT installed as a real agent
(it lives under `evals/smoke/fixtures/`, outside the plugin's `agents/` scan).

## Expected symptom (how the procedure catches it)

Point a scratch plugin's `agents/preship-verifier.md` at this file, reinstall,
and run the two enforcement rungs in a fresh session:

- `binding-honoured` → **FAIL**: the fork cannot quote the shipped unique first
  sentence (this fixture's differs), so the attestation is absent.
- `disallowed-tools-enforced` → **FAIL**: with `disallowedTools` gone, Write/Edit
  are present in the fork's schema and the `/tmp` probe file IS created.

Two clean FAILs against this fixture, contrasted with two PASSes against the
shipped `agents/preship-verifier.md`, demonstrate the rungs discriminate a live
binding from a degraded one — the whole point of the smoke gate (a green bats
suite proves neither).
