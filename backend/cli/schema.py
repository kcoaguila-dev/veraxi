"""Backward-compatibility forwarding to veraxi.cli.schema.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/schema.py.
"""

import sys

import veraxi.cli.schema

sys.modules[__name__] = veraxi.cli.schema
