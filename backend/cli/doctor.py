"""Backward-compatibility forwarding to veraxi.cli.doctor.

Single source of truth resides in packages/veraxi-cli/src/veraxi/cli/doctor.py.
"""
import sys

import veraxi.cli.doctor

sys.modules[__name__] = veraxi.cli.doctor
