"""#319: every command + skill frontmatter block must parse under strict YAML.

Claude Code's runtime parser is lenient; a strict parser (PyYAML) rejects an
unquoted ``description:`` whose value contains a colon+space, silently dropping
the whole block. This canary keeps the class closed after commands/sync.md and
commands/checklist-init.md were quoted (#319).
"""
import glob
import os

import pytest
import yaml

_REPO = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
_FILES = sorted(glob.glob(os.path.join(_REPO, "commands", "*.md"))) + sorted(
    glob.glob(os.path.join(_REPO, "skills", "*", "SKILL.md"))
)


@pytest.mark.parametrize(
    "path", _FILES, ids=[os.path.relpath(p, _REPO) for p in _FILES]
)
def test_frontmatter_is_strict_yaml(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    if not text.startswith("---"):
        pytest.skip("no frontmatter block")
    frontmatter = text.split("---", 2)[1]
    yaml.safe_load(frontmatter)  # raises yaml.YAMLError on a strict violation


def test_frontmatter_sweep_is_not_vacuous():
    # Fail loud if discovery breaks: an empty glob would make the parametrized
    # sweep collect zero cases and false-green instead of guarding anything.
    assert _FILES, "no commands/*.md or skills/*/SKILL.md discovered — check repo layout"


# #447: `claude plugin validate --strict` (which would reject unrecognized skill
# frontmatter keys) does NOT exist in claude 2.1.75, so this canary is the CI
# regression gate for the whole unrecognized-key class. It closed the
# `when-to-use:` (kebab, silently-dropped) → `when_to_use:` (snake, recognized)
# rename. Keys per the documented skill frontmatter reference
# (https://code.claude.com/docs/en/skills.md#frontmatter-reference).
_RECOGNIZED_SKILL_KEYS = frozenset(
    {
        "name",
        "description",
        "when_to_use",
        "argument-hint",
        "arguments",
        "disable-model-invocation",
        "user-invocable",
        "allowed-tools",
        "disallowed-tools",
        "model",
        "effort",
        "context",
        "agent",
        "hooks",
        "paths",
        "shell",
    }
)

_SKILL_FILES = sorted(glob.glob(os.path.join(_REPO, "skills", "*", "SKILL.md")))


@pytest.mark.parametrize(
    "path", _SKILL_FILES, ids=[os.path.relpath(p, _REPO) for p in _SKILL_FILES]
)
def test_skill_frontmatter_keys_are_recognized(path):
    """Every skill frontmatter key must be a recognized Claude Code field.

    Catches the `when-to-use` (kebab) unrecognized-key class the loader silently
    drops — and any future typo'd key — since `--strict` isn't available to.
    """
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    assert text.startswith("---"), f"{path}: skill missing frontmatter block"
    frontmatter = yaml.safe_load(text.split("---", 2)[1]) or {}
    unknown = sorted(set(frontmatter) - _RECOGNIZED_SKILL_KEYS)
    assert not unknown, (
        f"{os.path.relpath(path, _REPO)}: unrecognized frontmatter key(s) "
        f"{unknown} — silently dropped by the loader (see #447). "
        f"Recognized keys: {sorted(_RECOGNIZED_SKILL_KEYS)}"
    )


def test_skill_key_canary_is_not_vacuous():
    assert _SKILL_FILES, "no skills/*/SKILL.md discovered — canary would false-green"


# #448: every `allowed-tools` Bash grant must be SCOPED (`Bash(...)`), not
# a blanket `Bash` that auto-approves arbitrary shell for the turn — a trust
# problem for a distributed plugin. This canary pins the class so a new command
# can't re-introduce an unscoped grant.
# #452: sweep skills/ too. next/capture/ship carry the only Bash grants in
# skills/, and they arrived by moving OUT of commands/ — a commands-only glob
# would have silently dropped all three subjects the moment they converted.
_COMMAND_FILES = sorted(glob.glob(os.path.join(_REPO, "commands", "*.md")))
_GRANT_BEARING_FILES = _COMMAND_FILES + _SKILL_FILES


@pytest.mark.parametrize(
    "path",
    _GRANT_BEARING_FILES,
    ids=[os.path.relpath(p, _REPO) for p in _GRANT_BEARING_FILES],
)
def test_bash_grant_is_scoped(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    if not text.startswith("---"):
        pytest.skip("no frontmatter block")
    fm = yaml.safe_load(text.split("---", 2)[1]) or {}
    grant = fm.get("allowed-tools")
    if grant is None:
        return
    # allowed-tools is a comma-separated scalar; a bare `Bash` token (not
    # `Bash(...)`) is an unscoped grant.
    tokens = [t.strip() for t in str(grant).split(",")]
    assert "Bash" not in tokens, (
        f"{os.path.relpath(path, _REPO)}: unscoped `Bash` grant — scope it to "
        f"`Bash(bash ${{CLAUDE_PLUGIN_ROOT}}/scripts/*)` (see #448). Got: {grant!r}"
    )


def test_command_bash_canary_is_not_vacuous():
    assert _COMMAND_FILES, "no commands/*.md discovered — canary would false-green"


# #449: invocation-control invariants.
def _load_fm(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    if not text.startswith("---"):
        return {}
    return yaml.safe_load(text.split("---", 2)[1]) or {}


def test_all_core_skills_are_not_user_invocable():
    """The 14 internal core-* skills must be hidden from the user / menu."""
    core = sorted(glob.glob(os.path.join(_REPO, "skills", "core-*", "SKILL.md")))
    assert core, "no core-* skills discovered — canary would false-green"
    missing = [
        os.path.relpath(p, _REPO)
        for p in core
        if _load_fm(p).get("user-invocable") is not False
    ]
    assert not missing, f"core-* skills missing `user-invocable: false` (#449): {missing}"


def test_disable_model_invocation_only_on_operator_verbs():
    """CHAIN-safety invariant: `disable-model-invocation: true` may appear ONLY on
    auth/init/use — NEVER on a workflow-step command, or /devagent:next --auto's
    model-invocation of that step silently dies (#449)."""
    allowed = {"auth.md", "init.md", "use.md"}
    # #452: sweep skills/ too — `next` is a skill now, and the flag would break
    # the CHAIN from skills/next/SKILL.md exactly as it would from commands/next.md.
    # Skills share the basename SKILL.md, so it can never match the allow-list:
    # any skill carrying the flag is an offender, reported by its readable path.
    offenders = sorted(
        os.path.relpath(p, _REPO)
        for p in _COMMAND_FILES + _SKILL_FILES
        if _load_fm(p).get("disable-model-invocation") is True
        and os.path.basename(p) not in allowed
    )
    assert not offenders, (
        f"`disable-model-invocation: true` on non-operator command(s)/skill(s) {offenders} "
        f"— this breaks the /devagent:next --auto CHAIN. Allowed only on {sorted(allowed)}."
    )
    # And the three operator verbs MUST carry it (both directions of the invariant).
    # Commands-only by construction: all three are commands, and the offenders
    # sweep above already forbids the flag anywhere in skills/.
    have = {
        os.path.basename(p)
        for p in _COMMAND_FILES
        if _load_fm(p).get("disable-model-invocation") is True
    }
    assert have == allowed, f"disable-model-invocation set = {sorted(have)}, expected {sorted(allowed)}"


# #450: every slash command carries an `argument-hint` (autocomplete grammar).
# All devAgent commands take at least an optional [project]; the field was a
# closed gap of 19 commands. This canary keeps the coverage at 100% so a new
# command surfaces its grammar in / menu autocomplete.
@pytest.mark.parametrize(
    "path", _COMMAND_FILES, ids=[os.path.relpath(p, _REPO) for p in _COMMAND_FILES]
)
def test_command_has_argument_hint(path):
    hint = _load_fm(path).get("argument-hint")
    assert isinstance(hint, str) and hint.strip(), (
        f"{os.path.relpath(path, _REPO)}: missing/empty `argument-hint` "
        f"(copy the usage grammar up into frontmatter — see #450)"
    )
