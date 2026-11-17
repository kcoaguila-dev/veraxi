"""SSRF guard for outbound integration URLs.

Every URL the backend connects to on a tenant's behalf — MCP servers,
OpenAPI spec/server URLs, OAuth-adjacent fetches — must pass
:func:`validate_external_url` first, and again immediately before each
connection (which is what protects against DNS rebinding: the addresses
validated here are the ones resolved at validation time, so callers
validate as late as possible).

Policy: only ``http``/``https``; the hostname must resolve, and *every*
resolved address must be a public address. Loopback, private (RFC 1918),
link-local (including the cloud metadata range 169.254.0.0/16),
multicast, reserved, and unspecified addresses are rejected unless the
operator explicitly sets ``ALLOW_PRIVATE_MCP_URLS=true`` for local
self-hosted development.
"""

import ipaddress
import logging
import socket
from urllib.parse import urlparse

import sentry_sdk

logger = logging.getLogger(__name__)


class SsrfBlockedError(ValueError):
    """Raised when a URL fails SSRF validation."""


def _allow_private() -> bool:
    try:
        from backend.config import get_config

        return bool(get_config().allow_private_mcp_urls)
    except Exception:
        import os

        return os.environ.get("ALLOW_PRIVATE_MCP_URLS", "false").lower() == "true"


def _resolve(hostname: str) -> list[str]:
    """Resolve a hostname to a list of IP strings (seam for tests)."""
    infos = socket.getaddrinfo(hostname, None)
    addresses: list[str] = []
    for info in infos:
        sockaddr = info[4]
        if sockaddr:
            addr = str(sockaddr[0])
            if addr not in addresses:
                addresses.append(addr)
    return addresses


def _is_blocked_ip(ip_text: str) -> bool:
    try:
        ip = ipaddress.ip_address(ip_text)
    except ValueError:
        return True  # Unparseable resolver output: fail closed.
    return bool(
        ip.is_loopback
        or ip.is_private
        or ip.is_link_local
        or ip.is_multicast
        or ip.is_reserved
        or ip.is_unspecified
    )


def validate_external_url(url: str, *, allow_private: bool | None = None) -> str:
    """Validate an outbound URL and return it unchanged.

    Raises :class:`SsrfBlockedError` (a ``ValueError``) when the scheme
    is not http/https, the hostname is missing or unresolvable, or any
    resolved address is non-public. ``allow_private`` overrides the
    ``ALLOW_PRIVATE_MCP_URLS`` config when explicitly passed.
    """
    if not url or not isinstance(url, str):
        raise SsrfBlockedError("URL is required.")
    parsed = urlparse(url.strip())
    if parsed.scheme not in ("http", "https"):
        raise SsrfBlockedError(
            f"URL scheme must be http or https, got {parsed.scheme!r}."
        )
    hostname = parsed.hostname
    if not hostname:
        raise SsrfBlockedError("URL must include a hostname.")
    if allow_private is None:
        allow_private = _allow_private()
    if allow_private:
        return url
    try:
        addresses = _resolve(hostname)
    except OSError as e:
        sentry_sdk.capture_exception(e)
        raise SsrfBlockedError(
            f"Hostname {hostname!r} could not be resolved."
        ) from e
    if not addresses:
        raise SsrfBlockedError(f"Hostname {hostname!r} could not be resolved.")
    for address in addresses:
        if _is_blocked_ip(address):
            raise SsrfBlockedError(
                f"URL host {hostname!r} resolves to a non-public address "
                f"({address}); outbound connections to loopback, private, "
                "link-local, or metadata addresses are blocked."
            )
    return url
