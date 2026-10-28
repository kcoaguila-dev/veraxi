"""Backward-compatibility forwarding to veraxi.cli.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/.
"""
import importlib
import sys

import veraxi.cli

sys.modules[__name__] = veraxi.cli

# Pre-populate all known CLI submodules so `backend.cli.<submodule>` directly maps to `veraxi.cli.<submodule>`
_SUBMODULES = [
    "auth",
    "chat",
    "check",
    "client_configs",
    "cluster",
    "completion",
    "config",
    "context",
    "doctor",
    "hook",
    "impact",
    "ingest",
    "init_project",
    "learn",
    "main",
    "memory",
    "models",
    "query",
    "review",
    "rules",
    "schema",
    "stats",
    "trace",
    "utils",
    "web",
]

for _sub in _SUBMODULES:
    try:
        _mod = importlib.import_module(f"veraxi.cli.{_sub}")
        sys.modules[f"{__name__}.{_sub}"] = _mod
    except ImportError:
        pass

