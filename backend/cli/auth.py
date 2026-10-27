"""Backward-compatibility forwarding to veraxi.cli.auth.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/auth.py.
"""
import sys
import veraxi.cli.auth

sys.modules[__name__] = veraxi.cli.auth
