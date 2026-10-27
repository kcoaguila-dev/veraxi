"""Backward-compatibility forwarding to veraxi.cli.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/.
"""
import sys
import veraxi.cli

sys.modules[__name__] = veraxi.cli
