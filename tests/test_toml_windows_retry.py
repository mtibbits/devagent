"""#293 — regression tests for _toml.py's Windows transient-share retry.

Framework-agnostic on purpose: pytest collects the ``test_*`` functions in
CI (`python3 -m pytest tests/`), and the ``__main__`` block runs them under
a bare ``python3 tests/test_toml_windows_retry.py`` on a box without pytest
(e.g. the Windows dev machine). No fixtures — each test does its own
save/restore patching.

`os.name` is patched on the loaded module so the Windows retry branch is
exercised deterministically on a POSIX CI runner, and vice-versa.
"""

import importlib.util
import pathlib
import tempfile
import types
from contextlib import contextmanager

_TOML_PATH = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "lib" / "_toml.py"
_spec = importlib.util.spec_from_file_location("_toml_under_test", _TOML_PATH)
toml = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(toml)


@contextmanager
def _patched(os_name, no_sleep=True):
    """Force _toml's view of os.name (and silence backoff) for the duration.

    Swap the module *references* on `toml` — do NOT mutate the shared `os`
    module's `name` (that is process-wide and would make `pathlib.Path`
    build the foreign flavor, e.g. WindowsPath on Linux → NotImplemented/
    UnsupportedOperation). `_toml.py` only touches `os.name` and
    `time.sleep`, so tiny stand-ins cover it while pathlib/tempfile keep
    using the real os.
    """
    saved_os, saved_time = toml.os, toml.time
    toml.os = types.SimpleNamespace(name=os_name)
    toml.time = types.SimpleNamespace(sleep=(lambda _d: None) if no_sleep else saved_time.sleep)
    try:
        yield
    finally:
        toml.os, toml.time = saved_os, saved_time


def _raiser(n_fail, exc=PermissionError, ret="ok"):
    """Return a fn that raises `exc` its first n_fail calls, then returns ret.
    Carries a `.calls` counter."""
    state = {"calls": 0}
    def fn():
        state["calls"] += 1
        if state["calls"] <= n_fail:
            raise exc("simulated transient")
        return ret
    fn.state = state
    return fn


def test_passthrough_on_posix():
    # POSIX: helper calls fn once and lets the error propagate — no retry.
    with _patched("posix"):
        fn = _raiser(1)
        raised = False
        try:
            toml._retry_windows_share(fn)
        except PermissionError:
            raised = True
        assert raised, "POSIX passthrough must propagate the first error"
        assert fn.state["calls"] == 1, f"expected 1 call, got {fn.state['calls']}"


def test_retry_recovers_on_windows():
    with _patched("nt"):
        fn = _raiser(2, ret=42)
        assert toml._retry_windows_share(fn) == 42
        assert fn.state["calls"] == 3, f"expected 3 calls, got {fn.state['calls']}"


def test_reraise_after_exhaustion():
    with _patched("nt"):
        fn = _raiser(9999)  # always fails
        raised = False
        try:
            toml._retry_windows_share(fn)
        except PermissionError:
            raised = True
        assert raised, "must re-raise after exhausting retries"
        assert fn.state["calls"] == toml._RETRY_ATTEMPTS, \
            f"expected {toml._RETRY_ATTEMPTS} attempts, got {fn.state['calls']}"


def test_missing_not_retried_unless_flagged():
    # FileNotFoundError is retried ONLY with also_missing=True.
    with _patched("nt"):
        fn = _raiser(2, exc=FileNotFoundError, ret="v")
        raised = False
        try:
            toml._retry_windows_share(fn)  # also_missing defaults False
        except FileNotFoundError:
            raised = True
        assert raised and fn.state["calls"] == 1, "FNF must not retry by default"

        fn2 = _raiser(2, exc=FileNotFoundError, ret="v")
        assert toml._retry_windows_share(fn2, also_missing=True) == "v"
        assert fn2.state["calls"] == 3


def test_dump_survives_transient_replace():
    # End-to-end: a concurrent-reader sharing violation on the atomic replace
    # is retried, and _dump still lands the content.
    with _patched("nt"):
        real_replace = pathlib.Path.replace
        calls = {"n": 0}
        def flaky_replace(self, target):
            calls["n"] += 1
            if calls["n"] <= 2:
                raise PermissionError("simulated sharing violation")
            return real_replace(self, target)
        pathlib.Path.replace = flaky_replace
        try:
            with tempfile.TemporaryDirectory() as d:
                target = pathlib.Path(d) / "state.toml"
                toml._dump(target, {"k": "v", "n": 7})
                assert calls["n"] == 3, f"replace retried to success, got {calls['n']}"
                reloaded = toml._load(target)
                assert reloaded == {"k": "v", "n": 7}
        finally:
            pathlib.Path.replace = real_replace


def test_load_retry_wiring():
    # Pin the improve-pass decision: lock-free readers load with retry=True;
    # the mutation path's load (under _locked_rmw) loads with retry=False —
    # retrying under the exclusive lock would only stall serialized writers.
    # (os.name="posix" so the retry is a harmless passthrough; we inspect the
    # kwarg, not the retry behavior.)
    with _patched("posix"):
        seen = []
        real_load = toml._load
        def spy(path, retry=False):
            seen.append(retry)
            return real_load(path, retry=retry)
        toml._load = spy
        try:
            with tempfile.TemporaryDirectory() as d:
                f = pathlib.Path(d) / "s.toml"
                f.write_text('k = "v"\n')
                seen.clear(); toml.main(["get", str(f), "k"])
                assert seen == [True], f"get must _load(retry=True); saw {seen}"
                seen.clear(); toml.main(["set", str(f), "k2", '"w"'])
                assert seen == [False], f"locked mutation must _load(retry=False); saw {seen}"
        finally:
            toml._load = real_load


if __name__ == "__main__":
    import traceback
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for t in tests:
        try:
            t()
            print(f"ok   {t.__name__}")
        except Exception:
            failed += 1
            print(f"FAIL {t.__name__}")
            traceback.print_exc()
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    raise SystemExit(1 if failed else 0)
