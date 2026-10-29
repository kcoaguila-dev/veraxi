"""Backward-compatibility forwarding to veraxi.cli.utils.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/utils.py.
"""

import sys

import veraxi.cli.utils

sys.modules[__name__] = veraxi.cli.utils
