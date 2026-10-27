"""Backward-compatibility forwarding to veraxi.cli.check.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/check.py.
"""
import sys
import veraxi.cli.check

sys.modules[__name__] = veraxi.cli.check
