"""#532: the ratified versioning policy is SHA-tracking — NO version key.

Decision doc: devDoc Issue-532/decision-plugin-versioning.md. A plugin.json
``version`` wins over the marketplace entry and re-pins installed plugins,
breaking the reinstall-free SHA `/plugin update` flow (#445). ``--strict``
stays red on exactly this (documented-accepted in README §Versioning); this
guard is the CI-enforceable half of the decision. Revisit at go-public (#404).
"""
import json
import os

_REPO = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))


def _load(name):
    with open(os.path.join(_REPO, ".claude-plugin", name), encoding="utf-8") as fh:
        return json.load(fh)


def test_plugin_json_has_no_version_key():
    manifest = _load("plugin.json")
    assert "version" not in manifest, (
        "plugin.json grew a 'version' key — this re-pins installed plugins and "
        "breaks SHA-tracking updates (#445). The #532 decision prohibits it; "
        "see devDoc Issue-532/decision-plugin-versioning.md before changing."
    )


def test_marketplace_entries_have_no_version_key():
    entries = _load("marketplace.json").get("plugins", [])
    offenders = [e.get("name", "?") for e in entries if "version" in e]
    assert not offenders, (
        f"marketplace.json plugin entries {offenders} carry a 'version' key — "
        "the #532 policy is SHA-tracking (no version on either manifest)."
    )


def test_marketplace_guard_is_not_vacuous():
    # An empty plugins array would make the sweep above false-green.
    assert _load("marketplace.json").get("plugins"), (
        "marketplace.json has no plugin entries — guard would be vacuous"
    )
