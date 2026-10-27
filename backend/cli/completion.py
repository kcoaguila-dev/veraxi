"""Backward-compatibility forwarding to veraxi.cli.completion.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/completion.py.
"""
import sys
import veraxi.cli.completion

sys.modules[__name__] = veraxi.cli.completion
