"""Backward-compatibility forwarding to veraxi.cli.corpus.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/corpus.py.
"""

import sys

import veraxi.cli.corpus

sys.modules[__name__] = veraxi.cli.corpus
