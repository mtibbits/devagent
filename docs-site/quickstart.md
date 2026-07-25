<!-- derived-from: README.md commands/auth.md commands/init.md commands/pull.md commands/file.md skills/capture/SKILL.md -->
# Quickstart

From empty config to a merge-ready MR, using a GitHub-hosted project named
`myproj` as the example. Install first ([Install](./install.md)), then walk
these steps inside a Claude Code session.

## 1. Bootstrap the project

```
/devagent:init myproj
```

Interactive bootstrap of a new project under `~/.claude/devagent/`: registers
`myproj` in `config.toml` (source directory, devdoc directory, tracker/forge
backends, workflow permissions). Create the devdoc directory yourself if it
doesn't exist yet — init records the path; the workflow populates it
per-issue.

## 2. Set up auth — before any issue command

```
/devagent:auth create myproj github
```

Creates and stores a personal access token (mode-600 file under
`~/.claude/devagent/secrets/`). **Do this first**: the issue commands below
(`pull`, `file`) call the forge immediately and fail without a token.

## 3. Validate the setup

```
/devagent:doctor
```

The first-run validation and the troubleshooting entry point any time after:
checks config, state, paths, template resolution, and auth status per
backend.

## 4. Capture an idea and file it

```
/devagent:capture add a --dry-run flag to the exporter
/devagent:file <slug>
```

`capture` drafts the idea under your devdoc's `Captures/<slug>/` directory
and prints the slug; optionally red-team the draft with `/devagent:redissue`,
then `file <slug>` turns it into a real tracker issue. Note: `file` is gated
by `permissions.push_mr`, which ships `false` — it prints its plan and stops
until you confirm (and it asks again if the capture was never red-teamed).

## 5. Pull the issue

```
/devagent:pull myproj origin 42
```

Fetches issue #42 from the project's origin tracker and scaffolds its
workflow directory, including the checklist that tracks it through the
22-step loop.

## 6. Run the loop

```
/devagent:next --auto
```

Executes the next actionable step and chains onward until a permission gate
or a stuck step needs you. You'll see `checklist.md` advancing step by step,
per-step artifacts accumulating, and the MR opening at the ship step. See
the [workflow reference](./workflow.md) for every step.

[← devAgent onboarding](./index.md)
