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
