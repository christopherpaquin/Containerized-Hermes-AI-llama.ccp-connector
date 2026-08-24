"""Pytest bootstrap for the mempalace-remote plugin test suite.

Makes the plugin importable as `mempalace_remote` from a bare checkout:
  - adds the plugin directory to sys.path (its package dir is named with a
    hyphen, so it can't be `import`ed by that name directly)
  - falls back to a verbatim-copied stub of agent.memory_provider /
    agent.secret_scope (tests/_stubs/agent/) only if the real Hermes
    package isn't on the path — e.g. when running these tests inside the
    Hermes container itself, the real modules are used instead, exercising
    the actual installed ABC.

Run with:  python3 -m pytest plugins/mempalace-remote/tests
"""

from __future__ import annotations

import importlib
import importlib.util
import sys
from pathlib import Path

_TESTS_DIR = Path(__file__).resolve().parent
_PLUGIN_DIR = _TESTS_DIR.parent
_STUBS_DIR = _TESTS_DIR / "_stubs"

try:
    importlib.import_module("agent.memory_provider")
except ImportError:
    sys.path.insert(0, str(_STUBS_DIR))

if str(_PLUGIN_DIR) not in sys.path:
    sys.path.insert(0, str(_PLUGIN_DIR))

# The plugin package directory is `mempalace-remote` (hyphenated, matching
# Hermes's discovery convention), which isn't a legal Python module name.
# Load its __init__.py under the importable name `mempalace_remote` so
# tests can `import mempalace_remote`.
if "mempalace_remote" not in sys.modules:
    spec = importlib.util.spec_from_file_location(  # type: ignore[attr-defined]
        "mempalace_remote", _PLUGIN_DIR / "__init__.py"
    )
    module = importlib.util.module_from_spec(spec)  # type: ignore[attr-defined]
    sys.modules["mempalace_remote"] = module
    assert spec.loader is not None
    spec.loader.exec_module(module)
