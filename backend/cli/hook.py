"""Backward-compatibility forwarding to veraxi.cli.hook.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/hook.py.
"""
import sys

import veraxi.cli.hook

sys.modules[__name__] = veraxi.cli.hook
