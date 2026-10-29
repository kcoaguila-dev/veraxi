"""Backward-compatibility forwarding to veraxi.cli.impact.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/impact.py.
"""

import sys

import veraxi.cli.impact

sys.modules[__name__] = veraxi.cli.impact
