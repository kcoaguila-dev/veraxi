"""Unit tests for the integration secrets vault (token_vault.py)."""

import os

import pytest

from backend.security import token_vault
from backend.security.token_vault import (
    TokenVaultError,
    decrypt_secrets,
    encrypt_secrets,
)


@pytest.fixture(autouse=True)
def _vault_key(monkeypatch):
    monkeypatch.setenv("INTEGRATION_ENCRYPTION_KEY", "test-vault-key-material")
    monkeypatch.delenv("VERAXI_ENV", raising=False)
    monkeypatch.delenv("ENVIRONMENT", raising=False)
    from backend.config import get_config

    get_config.cache_clear()
    yield
    get_config.cache_clear()


class TestRoundTrip:
    def test_round_trip(self):
        secrets = {"access_token": "abc123", "headers": {"X-Api-Key": "k"}}
        ciphertext = encrypt_secrets(secrets)
        assert ciphertext != "abc123"
        assert "abc123" not in ciphertext
        assert decrypt_secrets(ciphertext) == secrets

    def test_empty_secrets_round_trip(self):
        assert decrypt_secrets(encrypt_secrets({})) == {}

    def test_none_and_empty_ciphertext(self):
        assert decrypt_secrets(None) == {}
        assert decrypt_secrets("") == {}

    def test_fernet_key_format_accepted(self, monkeypatch):
        from cryptography.fernet import Fernet

        monkeypatch.setenv(
            "INTEGRATION_ENCRYPTION_KEY", Fernet.generate_key().decode()
        )
        from backend.config import get_config

        get_config.cache_clear()
        ciphertext = encrypt_secrets({"api_key": "xyz"})
        assert decrypt_secrets(ciphertext) == {"api_key": "xyz"}


class TestTamperFailure:
    def test_tampered_ciphertext_fails_closed(self):
        ciphertext = encrypt_secrets({"access_token": "abc123"})
        tampered = ciphertext[:-4] + ("AAAA" if not ciphertext.endswith("AAAA") else "BBBB")
        with pytest.raises(TokenVaultError):
            decrypt_secrets(tampered)

    def test_wrong_key_fails_closed(self, monkeypatch):
        ciphertext = encrypt_secrets({"access_token": "abc123"})
        monkeypatch.setenv("INTEGRATION_ENCRYPTION_KEY", "a-different-key")
        from backend.config import get_config

        get_config.cache_clear()
        with pytest.raises(TokenVaultError):
            decrypt_secrets(ciphertext)

    def test_garbage_ciphertext_fails_closed(self):
        with pytest.raises(TokenVaultError):
            decrypt_secrets("not-a-ciphertext")


class TestProductionFailClosed:
    def test_missing_key_in_production_raises(self, monkeypatch):
        monkeypatch.delenv("INTEGRATION_ENCRYPTION_KEY", raising=False)
        monkeypatch.setenv("VERAXI_ENV", "production")
        from backend.config import get_config

        get_config.cache_clear()
        # Config reads INTEGRATION_ENCRYPTION_KEY at build time; ensure
        # the cached config really has no key for this scenario.
        if get_config().integration_encryption_key:
            pytest.skip("environment provides a real key")
        with pytest.raises(TokenVaultError):
            encrypt_secrets({"access_token": "x"})

    def test_is_configured(self):
        assert token_vault.is_configured() is True
        assert os.environ.get("INTEGRATION_ENCRYPTION_KEY")
