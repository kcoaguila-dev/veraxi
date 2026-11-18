"""Backward-compatibility forwarding to veraxi.cli.evals.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/evals.py.
"""

import sys

import veraxi.cli.evals

sys.modules[__name__] = veraxi.cli.evals
