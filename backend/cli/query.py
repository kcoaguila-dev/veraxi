"""Backward-compatibility forwarding to veraxi.cli.query.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/query.py.
"""
import sys

import veraxi.cli.query

sys.modules[__name__] = veraxi.cli.query
