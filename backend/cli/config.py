"""Backward-compatibility forwarding to veraxi.cli.config.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/config.py.
"""

import sys

import veraxi.cli.config

sys.modules[__name__] = veraxi.cli.config
