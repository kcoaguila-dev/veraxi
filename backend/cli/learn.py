"""Backward-compatibility forwarding to veraxi.cli.learn.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/learn.py.
"""

import sys

import veraxi.cli.learn

sys.modules[__name__] = veraxi.cli.learn
