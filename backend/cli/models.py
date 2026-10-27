"""Backward-compatibility forwarding to veraxi.cli.models.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/models.py.
"""
import sys
import veraxi.cli.models

sys.modules[__name__] = veraxi.cli.models
