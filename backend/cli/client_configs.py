"""Backward-compatibility forwarding to veraxi.cli.client_configs.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/client_configs.py.
"""

import sys

import veraxi.cli.client_configs

sys.modules[__name__] = veraxi.cli.client_configs
