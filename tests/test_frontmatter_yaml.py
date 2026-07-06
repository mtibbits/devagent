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
    text = open(path, encoding="utf-8").read()
    if not text.startswith("---"):
        pytest.skip("no frontmatter block")
    frontmatter = text.split("---", 2)[1]
    yaml.safe_load(frontmatter)  # raises yaml.YAMLError on a strict violation
