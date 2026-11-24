"""``veraxi-runner`` CLI entry point.

Usage:
    veraxi-runner connect --url wss://veraxi.me --token <TOKEN> \
        --repo <PATH> --runtime microsandbox|docker [--tenant-id <ID>]

The token may also come from the ``VERAXI_RUNNER_TOKEN`` environment
variable. The tenant id may come from ``VERAXI_TENANT_ID``.
"""

import argparse
import logging
import os
import sys


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO)
    parser = argparse.ArgumentParser(prog="veraxi-runner")
    sub = parser.add_subparsers(dest="command", required=True)
    connect = sub.add_parser("connect", help="Connect this machine as a sandbox runner")
    connect.add_argument("--url", required=True, help="Backend base URL, e.g. wss://veraxi.me")
    connect.add_argument("--token", default=None, help="Runner token (or VERAXI_RUNNER_TOKEN)")
    connect.add_argument("--repo", required=True, help="Path to the repository worktree to expose")
    connect.add_argument("--runtime", choices=["microsandbox", "docker", "direct"], default="docker")
    connect.add_argument("--tenant-id", default=None, help="Tenant id (or VERAXI_TENANT_ID)")
    connect.add_argument("--offline", action="store_true", help="Disable networking for commands")
    connect.add_argument("--enable-acp", action="store_true", help="Enable local ACP bridge (e.g. agy acp)")
    args = parser.parse_args(argv)

    if args.command == "connect":
        token = args.token or os.environ.get("VERAXI_RUNNER_TOKEN", "")
        if not token:
            parser.error("--token or VERAXI_RUNNER_TOKEN is required")
        tenant_id = args.tenant_id or os.environ.get("VERAXI_TENANT_ID", "")
        from veraxi_runner.client import run_connect

        run_connect(
            args.url, token, args.repo, args.runtime, tenant_id, args.offline,
            enable_acp=args.enable_acp,
        )
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
