"""Encryption vault for external-integration secrets.

Integration secrets (OAuth access/refresh tokens, MCP auth headers,
OpenAPI keys) are stored in Supabase as a single Fernet ciphertext in
``tenant_integrations.encrypted_secrets``. This module is the only place
that encrypts or decrypts them.

Key handling:

- The key comes from ``INTEGRATION_ENCRYPTION_KEY`` (see
  :class:`backend.config.Config`). It may be a ready-made Fernet key
  (urlsafe-base64, 32 bytes) or any non-empty passphrase, which is
  deterministically stretched with SHA-256 into a Fernet key.
- In production (``VERAXI_ENV``/``ENVIRONMENT`` set to ``production`` or
  ``prod``) a missing key fails closed: encrypting or decrypting raises
  :class:`TokenVaultError` instead of silently storing plaintext or
  generating an ephemeral key whose ciphertexts would be unreadable
  after a restart.
- Outside production a missing key generates an ephemeral in-process
  key and logs a warning, so local development keeps working.

Decrypted secrets are never logged.
"""

import base64
import hashlib
import json
import logging
import os

import sentry_sdk
from cryptography.fernet import Fernet, InvalidToken

logger = logging.getLogger(__name__)

_PRODUCTION_ENVS = {"production", "prod"}
_ephemeral_fernet: Fernet | None = None


class TokenVaultError(Exception):
    """Raised when integration secrets cannot be encrypted or decrypted."""


def _is_production() -> bool:
    env = os.environ.get("VERAXI_ENV") or os.environ.get("ENVIRONMENT") or ""
    return env.strip().lower() in _PRODUCTION_ENVS


def _configured_key() -> str:
    # Read through Config when possible so tests that patch the
    # environment before get_config() runs behave the same as the app;
    # fall back to the raw environment if Config cannot be built.
    try:
        from backend.config import get_config

        return get_config().integration_encryption_key or ""
    except Exception:
        return os.environ.get("INTEGRATION_ENCRYPTION_KEY", "")


def _fernet_from_material(material: str) -> Fernet:
    material = material.strip()
    try:
        # A valid Fernet key decodes to exactly 32 bytes.
        if len(base64.urlsafe_b64decode(material.encode())) == 32:
            return Fernet(material.encode())
    except Exception:  # Not a Fernet key — fall through to passphrase mode.
        logger.debug("INTEGRATION_ENCRYPTION_KEY is a passphrase, not a Fernet key")
    digest = hashlib.sha256(material.encode()).digest()
    return Fernet(base64.urlsafe_b64encode(digest))


def _get_fernet() -> Fernet:
    global _ephemeral_fernet
    material = _configured_key()
    if material:
        return _fernet_from_material(material)
    if _is_production():
        raise TokenVaultError(
            "INTEGRATION_ENCRYPTION_KEY is not set; refusing to store or "
            "read integration secrets in production."
        )
    if _ephemeral_fernet is None:
        logger.warning(
            "INTEGRATION_ENCRYPTION_KEY is not set; using an ephemeral "
            "in-process key. Stored integration secrets will be "
            "unreadable after a restart."
        )
        _ephemeral_fernet = Fernet(Fernet.generate_key())
    return _ephemeral_fernet


def is_configured() -> bool:
    """True when a durable encryption key is configured."""
    return bool(_configured_key())


def encrypt_secrets(secrets: dict) -> str:
    """Encrypt a secrets dict to a Fernet ciphertext string."""
    if not isinstance(secrets, dict):
        raise TokenVaultError("Integration secrets must be a JSON object.")
    plaintext = json.dumps(secrets).encode()
    return _get_fernet().encrypt(plaintext).decode()


def decrypt_secrets(ciphertext: str | None) -> dict:
    """Decrypt a ciphertext produced by :func:`encrypt_secrets`.

    Returns an empty dict for empty/None ciphertext. Raises
    :class:`TokenVaultError` on tampered or undecryptable ciphertext —
    callers must fail closed rather than treat it as "no secrets".
    """
    if not ciphertext:
        return {}
    try:
        plaintext = _get_fernet().decrypt(ciphertext.encode())
    except InvalidToken as e:
        sentry_sdk.capture_exception(e)
        raise TokenVaultError(
            "Stored integration secrets could not be decrypted "
            "(tampered ciphertext or wrong INTEGRATION_ENCRYPTION_KEY)."
        ) from e
    try:
        data = json.loads(plaintext.decode())
    except (ValueError, UnicodeDecodeError) as e:
        sentry_sdk.capture_exception(e)
        raise TokenVaultError("Stored integration secrets are corrupt.") from e
    if not isinstance(data, dict):
        raise TokenVaultError("Stored integration secrets are corrupt.")
    return data
