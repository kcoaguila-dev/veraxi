"""Backward-compatibility forwarding to veraxi.cli.chat.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/chat.py.
"""

import sys

import veraxi.cli.chat

sys.modules[__name__] = veraxi.cli.chat
