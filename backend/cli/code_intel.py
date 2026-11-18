"""Backward-compatibility forwarding to veraxi.cli.code_intel.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/code_intel.py.
"""

import sys

import veraxi.cli.code_intel

sys.modules[__name__] = veraxi.cli.code_intel
