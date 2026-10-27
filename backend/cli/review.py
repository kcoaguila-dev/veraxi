"""Backward-compatibility forwarding to veraxi.cli.review.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/review.py.
"""
import sys
import veraxi.cli.review

sys.modules[__name__] = veraxi.cli.review
