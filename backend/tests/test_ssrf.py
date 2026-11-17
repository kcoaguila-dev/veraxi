"""Unit tests for the SSRF guard (backend/security/ssrf.py).

DNS is mocked at the ``backend.security.ssrf._resolve`` seam so no real
network access happens and rebinding-style hostnames (public name,
private address) can be simulated exactly.
"""

import pytest

from backend.security import ssrf
from backend.security.ssrf import SsrfBlockedError, validate_external_url


def _mock_resolve(monkeypatch, mapping):
    def fake_resolve(hostname):
        if hostname in mapping:
            return mapping[hostname]
        raise OSError(f"no such host: {hostname}")

    monkeypatch.setattr(ssrf, "_resolve", fake_resolve)
    monkeypatch.setattr(ssrf, "_allow_private", lambda: False)


class TestSchemeEnforcement:
    def test_rejects_file_scheme(self, monkeypatch):
        _mock_resolve(monkeypatch, {})
        with pytest.raises(SsrfBlockedError):
            validate_external_url("file:///etc/passwd")

    def test_rejects_ftp_scheme(self, monkeypatch):
        _mock_resolve(monkeypatch, {})
        with pytest.raises(SsrfBlockedError):
            validate_external_url("ftp://example.com/x")

    def test_rejects_missing_hostname(self, monkeypatch):
        _mock_resolve(monkeypatch, {})
        with pytest.raises(SsrfBlockedError):
            validate_external_url("https://")

    def test_rejects_empty_url(self, monkeypatch):
        _mock_resolve(monkeypatch, {})
        with pytest.raises(SsrfBlockedError):
            validate_external_url("")


class TestPrivateAddressRejection:
    @pytest.mark.parametrize(
        "ip",
        [
            "127.0.0.1",  # IPv4 loopback
            "127.5.0.9",  # loopback /8
            "::1",  # IPv6 loopback
            "10.0.0.5",  # RFC1918
            "172.16.3.4",  # RFC1918
            "172.31.255.255",  # RFC1918 edge
            "192.168.1.10",  # RFC1918
            "169.254.169.254",  # cloud metadata (AWS/GCP)
            "169.254.0.1",  # link-local
            "fe80::1",  # IPv6 link-local
            "0.0.0.0",  # unspecified
            "224.0.0.1",  # multicast
        ],
    )
    def test_rejects_non_public_ips(self, monkeypatch, ip):
        _mock_resolve(monkeypatch, {"evil.example.com": [ip]})
        with pytest.raises(SsrfBlockedError):
            validate_external_url("https://evil.example.com/mcp")

    def test_literal_metadata_ip_rejected(self, monkeypatch):
        _mock_resolve(monkeypatch, {"169.254.169.254": ["169.254.169.254"]})
        with pytest.raises(SsrfBlockedError):
            validate_external_url("http://169.254.169.254/latest/meta-data/")

    def test_rebinding_hostname_resolving_private_rejected(self, monkeypatch):
        # Public-looking hostname whose DNS answer is private: the
        # classic DNS-rebinding shape. Validation must reject based on
        # the resolved address, not the name.
        _mock_resolve(monkeypatch, {"rebind.example.com": ["93.184.216.34", "10.1.2.3"]})
        with pytest.raises(SsrfBlockedError):
            validate_external_url("https://rebind.example.com/mcp")

    def test_localhost_rejected(self, monkeypatch):
        _mock_resolve(monkeypatch, {"localhost": ["127.0.0.1"]})
        with pytest.raises(SsrfBlockedError):
            validate_external_url("http://localhost:8000/mcp")


class TestPublicAddressesAllowed:
    def test_public_ipv4_allowed(self, monkeypatch):
        _mock_resolve(monkeypatch, {"mcp.example.com": ["93.184.216.34"]})
        url = "https://mcp.example.com/mcp"
        assert validate_external_url(url) == url

    def test_public_ipv6_allowed(self, monkeypatch):
        _mock_resolve(monkeypatch, {"mcp.example.com": ["2606:2800:220:1:248:1893:25c8:1946"]})
        url = "https://mcp.example.com/mcp"
        assert validate_external_url(url) == url

    def test_unresolvable_host_rejected(self, monkeypatch):
        _mock_resolve(monkeypatch, {})
        with pytest.raises(SsrfBlockedError):
            validate_external_url("https://does-not-resolve.example.com/mcp")

    def test_allow_private_override(self, monkeypatch):
        _mock_resolve(monkeypatch, {"localhost": ["127.0.0.1"]})
        url = "http://localhost:8000/mcp"
        assert validate_external_url(url, allow_private=True) == url
