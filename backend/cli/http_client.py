"""Backward-compatibility forwarding to veraxi.cli.http_client.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/http_client.py.
"""

import sys

import veraxi.cli.http_client

sys.modules[__name__] = veraxi.cli.http_client
