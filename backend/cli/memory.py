"""Backward-compatibility forwarding to veraxi.cli.memory.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/memory.py.
"""
import sys
import veraxi.cli.memory

sys.modules[__name__] = veraxi.cli.memory
