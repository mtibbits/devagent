"""#541 ratified DROP: superpowers is recommended, never declared.

A dependencies key re-inflicts the measured wholesale-disable
(analysis/2026-07-25-probe-dependency-semantics.md): no auto-install,
silent install success, dead plugin. Both manifest homes swept
(Issue-76/82: sibling sites travel in pairs).
"""
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent


def test_plugin_manifest_has_no_dependencies_key():
    manifest = json.loads((ROOT / ".claude-plugin" / "plugin.json").read_text())
    assert "dependencies" not in manifest


def test_marketplace_entries_have_no_dependencies_key():
    mp = json.loads((ROOT / ".claude-plugin" / "marketplace.json").read_text())
    plugins = mp["plugins"]
    assert plugins, "plugins array empty — guard would be vacuous (Issue-151)"
    for entry in plugins:
        assert "dependencies" not in entry
