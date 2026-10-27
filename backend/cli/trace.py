"""Backward-compatibility forwarding to veraxi.cli.trace.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/trace.py.
"""
import sys
import veraxi.cli.trace

sys.modules[__name__] = veraxi.cli.trace
