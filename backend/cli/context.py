"""Backward-compatibility forwarding to veraxi.cli.context.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/context.py.
"""
import sys
import veraxi.cli.context

sys.modules[__name__] = veraxi.cli.context
