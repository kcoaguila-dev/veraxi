"""Hybrid agentic coding sandboxes (Modal / E2B / remote MCP / runner)."""

from backend.sandbox.base import (
    ExecEvent,
    SandboxError,
    SandboxProvider,
    SandboxSessionInfo,
)
from backend.sandbox.manager import SandboxManager, get_default_manager
from backend.sandbox.policy import classify_command, requires_approval

__all__ = [
    "ExecEvent",
    "SandboxError",
    "SandboxManager",
    "SandboxProvider",
    "SandboxSessionInfo",
    "classify_command",
    "get_default_manager",
    "requires_approval",
]
