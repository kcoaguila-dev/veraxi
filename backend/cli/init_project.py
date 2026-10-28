"""Backward-compatibility forwarding to veraxi.cli.init_project.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/init_project.py.
"""
import sys

import veraxi.cli.init_project

sys.modules[__name__] = veraxi.cli.init_project
