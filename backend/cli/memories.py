"""Backward-compatibility forwarding to veraxi.cli.memories.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/memories.py.
"""

import sys

import veraxi.cli.memories

sys.modules[__name__] = veraxi.cli.memories
