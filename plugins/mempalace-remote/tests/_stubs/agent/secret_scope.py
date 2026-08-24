"""TEST FIXTURE ONLY — minimal stand-in for Hermes's agent.secret_scope.

The real module resolves secrets through gateway profile-scoping; this
fallback (used only when the real module isn't importable) just reads
os.environ, which is sufficient for exercising this plugin's own logic.
"""

from __future__ import annotations

import os
from typing import Optional


def get_secret(name: str, default: Optional[str] = None) -> Optional[str]:
    return os.environ.get(name, default)
