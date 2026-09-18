"""#532, re-taken at go-public (2026-09-18): the versioning policy is explicit
semver releases.

Decision doc: devDoc Issue-532/decision-plugin-versioning.md (2026-09-18
addendum). ``.claude-plugin/plugin.json`` carries the release ``version``; the
marketplace entry carries none, because Claude Code uses the plugin.json value
without warning when both are set, so a second copy can only go stale. A
plugin.json ``version`` pins every marketplace install to that string, so a
release is: bump the version, cut the matching CHANGELOG section, merge, then
``claude plugin tag --push`` (README §Versioning & releases). These guards keep
the three from drifting apart. Until 1.0.0 the plugin was versioned by git
commit SHA (#445) and this file asserted the opposite.
"""
import json
import os
import re

_REPO = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))

# semver.org §2 core grammar plus the optional pre-release / build suffixes.
_SEMVER = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$"
)


def _load(name):
    with open(os.path.join(_REPO, ".claude-plugin", name), encoding="utf-8") as fh:
        return json.load(fh)


def _plugin_version():
    return _load("plugin.json").get("version")


def test_plugin_json_has_semver_version():
    version = _plugin_version()
    assert isinstance(version, str) and _SEMVER.match(version), (
        f"plugin.json 'version' is {version!r}; a release needs a semver string "
        "there — it is what every marketplace install pins to (#532 re-take, "
        "README §Versioning & releases)."
    )


def test_marketplace_entries_have_no_version_key():
    entries = _load("marketplace.json").get("plugins", [])
    offenders = [e.get("name", "?") for e in entries if "version" in e]
    assert not offenders, (
        f"marketplace.json plugin entries {offenders} carry a 'version' key — "
        "plugin.json is the single version home; Claude Code uses its value "
        "over the marketplace entry without warning, so a copy here can only "
        "go stale (#532 re-take)."
    )


def test_marketplace_guard_is_not_vacuous():
    # An empty plugins array would make the sweep above false-green.
    assert _load("marketplace.json").get("plugins"), (
        "marketplace.json has no plugin entries — guard would be vacuous"
    )


def test_changelog_has_section_for_plugin_version():
    version = _plugin_version()
    with open(os.path.join(_REPO, "CHANGELOG.md"), encoding="utf-8") as fh:
        headings = [ln for ln in fh if ln.startswith("## ")]
    assert any(ln.startswith(f"## [{version}]") for ln in headings), (
        f"CHANGELOG.md has no '## [{version}]' section for the plugin.json "
        "version — a bump without a cut changelog section ships a release with "
        "no notes (README §Versioning & releases, step 2)."
    )
