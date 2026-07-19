---
name: preship-verifier
description: BROKEN-BINDING FIXTURE (#530) — do NOT install as a real agent. This copy has disallowedTools REMOVED and a mangled first sentence, to demonstrate the smoke procedure catches a degraded binding.
effort: high
---

# preship-verifier (BROKEN FIXTURE)

This fixture agent has NO disallowedTools line and its first sentence does NOT
match the shipped agents/preship-verifier.md. If a harness under test bound
this file, the `binding-honoured` rung would fail (the shipped unique sentence
would be absent) and `disallowed-tools-enforced` would fail (Write/Edit present
in the schema, and the /tmp path WOULD be created). It exists so the documented
procedure has a known-failing input to prove it discriminates.
