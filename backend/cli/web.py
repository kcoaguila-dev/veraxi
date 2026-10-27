"""Backward-compatibility forwarding to veraxi.cli.web.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/web.py.
"""
import sys
import veraxi.cli.web

sys.modules[__name__] = veraxi.cli.web
