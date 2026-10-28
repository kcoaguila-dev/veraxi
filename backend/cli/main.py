"""Backward-compatibility forwarding to veraxi.cli.main.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/main.py.
"""

import sys

import veraxi.cli.main

sys.modules[__name__] = veraxi.cli.main
