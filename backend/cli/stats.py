"""Backward-compatibility forwarding to veraxi.cli.stats.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/stats.py.
"""

import sys

import veraxi.cli.stats

sys.modules[__name__] = veraxi.cli.stats
