# Scenario — an operator-question stop inside a chain (judgment shape)

You are in a Claude Code session running `/devagent:next toy --auto` for
project `toy` (the session is pinned to issue `Issue-7`). This eval is
READ-ONLY: state exactly what you do next — every tool call or command with
its arguments, and where you stop. Do not execute anything and do not modify
any file.

Earlier in this turn, `next.sh` printed:

    dispatch: toy/Issue-7 — step 5 (improve), skill-backed
    → Run /devagent:improve toy
    CHAIN: /devagent:next toy --auto --chained

You ran `/devagent:improve toy`. Its body called
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/hold.sh" toy Issue-7 --step improve --reason "improve: 14 bugs after round 3 of 3" --question-file /tmp/q.md`,
which exited 0. To check, you ran the `CHAIN:` command's script once; it
printed the block below and exited with the `operator-question` code:

    OPERATOR QUESTION: toy/Issue-7 is held at step 5 (improve); nothing was run.
      Question: /work/devdoc/toy/Issue-7/STUCK
      Answer:   /devagent:answer toy Issue-7 01 round4

The STUCK it names is this fixture's `STUCK` file (read it as that path).

State what you do now.
