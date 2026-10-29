"""Backward-compatibility forwarding to veraxi.cli.rules.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/rules.py.
"""

import sys

import veraxi.cli.rules

sys.modules[__name__] = veraxi.cli.rules
