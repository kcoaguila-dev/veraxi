"""Backward-compatibility forwarding to veraxi.cli.ingest.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/ingest.py.
"""
import sys

import veraxi.cli.ingest

sys.modules[__name__] = veraxi.cli.ingest
