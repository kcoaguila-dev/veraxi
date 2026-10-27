"""Backward-compatibility forwarding to veraxi.cli.cluster.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/cluster.py.
"""
import sys
import veraxi.cli.cluster

sys.modules[__name__] = veraxi.cli.cluster
