"""Unit tests for the hardened MCP client manager.

Transports are patched at the manager's seams (``_open_session`` /
``_with_session``) so no real network or MCP server is involved.
"""

import re

import pytest

from backend.security.ssrf import SsrfBlockedError
from backend.services import mcp_client_manager as mgr

NAME_RE = re.compile(r"^[a-zA-Z0-9_-]{1,64}$")


class _FakeTool:
    def __init__(self, name, description="tool"):
        self.name = name
        self.description = description
        self.input_schema = {"type": "object", "properties": {}}


class _FakeListResult:
    def __init__(self, tools):
        self.tools = tools


class _FakeSession:
    def __init__(self, tool_names):
        self._tool_names = tool_names
        self.called = []

    async def list_tools(self):
        return _FakeListResult([_FakeTool(n) for n in self._tool_names])

    async def call_tool(self, name, args):
        self.called.append((name, args))
        return f"result:{name}"


@pytest.fixture(autouse=True)
def _clear_cache():
    mgr.invalidate_cache()
    yield
    mgr.invalidate_cache()


def _spec(slug="my-server", url="https://mcp.example.com/mcp", transport="auto"):
    return mgr.McpServerSpec(
        slug=slug, url=url, transport=transport, integration_id=f"id-{slug}"
    )


class TestSanitizeToolName:
    def test_basic_namespacing(self):
        assert mgr.sanitize_tool_name("my-server", "search") == "mcp__my-server__search"

    def test_invalid_chars_replaced(self):
        name = mgr.sanitize_tool_name("my server!", "fetch/data.now")
        assert NAME_RE.match(name)
        assert name == "mcp__my_server___fetch_data_now"

    def test_long_names_truncated_with_hash(self):
        long_tool = "a" * 100
        name = mgr.sanitize_tool_name("server", long_tool)
        assert len(name) <= 64
        assert NAME_RE.match(name)

    def test_truncation_is_unique_per_tool(self):
        a = mgr.sanitize_tool_name("server", "x" * 90 + "alpha")
        b = mgr.sanitize_tool_name("server", "x" * 90 + "omega")
        assert a != b
        assert len(a) <= 64 and len(b) <= 64


class TestDiscoveryAndCache:
    async def _fake_with_session(self, spec, action, session):
        return await action(session)

    @pytest.mark.asyncio
    async def test_discovery_maps_and_caches(self, monkeypatch):
        session = _FakeSession(["search", "fetch"])
        calls = {"n": 0}

        async def fake_with_session(spec, action):
            calls["n"] += 1
            return await action(session)

        monkeypatch.setattr(mgr, "_with_session", fake_with_session)
        spec = _spec()
        tools = await mgr.discover_tools(spec, "tenant-1")
        assert [t["function"]["name"] for t in tools] == [
            "mcp__my-server__search",
            "mcp__my-server__fetch",
        ]
        again = await mgr.discover_tools(spec, "tenant-1")
        assert again == tools
        assert calls["n"] == 1  # second call served from cache

    @pytest.mark.asyncio
    async def test_cache_isolated_per_tenant(self, monkeypatch):
        session = _FakeSession(["search"])
        calls = {"n": 0}

        async def fake_with_session(spec, action):
            calls["n"] += 1
            return await action(session)

        monkeypatch.setattr(mgr, "_with_session", fake_with_session)
        spec = _spec()
        await mgr.discover_tools(spec, "tenant-1")
        await mgr.discover_tools(spec, "tenant-2")
        assert calls["n"] == 2  # tenant-2 did not reuse tenant-1's cache

    @pytest.mark.asyncio
    async def test_invalidate_cache(self, monkeypatch):
        session = _FakeSession(["search"])
        calls = {"n": 0}

        async def fake_with_session(spec, action):
            calls["n"] += 1
            return await action(session)

        monkeypatch.setattr(mgr, "_with_session", fake_with_session)
        spec = _spec()
        await mgr.discover_tools(spec, "tenant-1")
        mgr.invalidate_cache(integration_id="id-my-server")
        await mgr.discover_tools(spec, "tenant-1")
        assert calls["n"] == 2

    @pytest.mark.asyncio
    async def test_discovery_timeout(self, monkeypatch):
        import asyncio

        async def slow_with_session(spec, action):
            await asyncio.sleep(5)

        monkeypatch.setattr(mgr, "_with_session", slow_with_session)
        monkeypatch.setattr(mgr, "DISCOVERY_TIMEOUT_SECONDS", 0.05)
        with pytest.raises((TimeoutError, asyncio.TimeoutError)):
            await mgr.discover_tools(_spec(), "tenant-1")


class TestTransportFallback:
    @pytest.mark.asyncio
    async def test_auto_falls_back_to_sse_on_404(self, monkeypatch):
        session = _FakeSession(["search"])
        seen = []

        class Fake404(Exception):
            status_code = 404

        async def fake_open(spec, transport, stack):
            seen.append(transport)
            if transport == "streamable_http":
                raise Fake404("not found")
            return session

        monkeypatch.setattr(mgr, "_open_session", fake_open)
        monkeypatch.setattr(mgr, "validate_external_url", lambda url, **k: url)

        async def action(sess):
            result = await sess.list_tools()
            return [t.name for t in result.tools]

        names = await mgr._with_session(_spec(), action)
        assert names == ["search"]
        assert seen == ["streamable_http", "sse"]

    @pytest.mark.asyncio
    async def test_no_fallback_on_other_errors(self, monkeypatch):
        class Fake500(Exception):
            status_code = 500

        async def fake_open(spec, transport, stack):
            raise Fake500("boom")

        monkeypatch.setattr(mgr, "_open_session", fake_open)
        monkeypatch.setattr(mgr, "validate_external_url", lambda url, **k: url)

        async def action(sess):  # pragma: no cover - never reached
            return None

        with pytest.raises(Fake500):
            await mgr._with_session(_spec(), action)


class TestSsrfEnforcement:
    @pytest.mark.asyncio
    async def test_metadata_ip_blocked_before_connect(self, monkeypatch):
        opened = []

        async def fake_open(spec, transport, stack):
            opened.append(transport)
            return _FakeSession([])

        monkeypatch.setattr(mgr, "_open_session", fake_open)
        spec = _spec(url="http://169.254.169.254/mcp")
        with pytest.raises(SsrfBlockedError):
            await mgr.discover_tools(spec, "tenant-1")
        assert opened == []


class TestSpecLoading:
    def _rows(self):
        return [
            {
                "id": "int-1",
                "kind": "mcp",
                "provider": "custom_mcp",
                "slug": "alpha",
                "display_name": "Alpha",
                "config": {"url": "https://a.example.com/mcp", "transport": "sse"},
                "encrypted_secrets": "x",
                "is_enabled": True,
            },
            {
                "id": "int-2",
                "kind": "mcp",
                "provider": "custom_mcp",
                "slug": "beta",
                "display_name": "Beta",
                "config": {"url": "https://b.example.com/mcp"},
                "encrypted_secrets": None,
                "is_enabled": True,
            },
            {
                "id": "int-3",
                "kind": "oauth",
                "provider": "github",
                "slug": "github",
                "display_name": "GitHub",
                "config": {},
                "encrypted_secrets": "x",
                "is_enabled": True,
            },
        ]

    def test_specs_from_integrations_decrypts_headers(self, monkeypatch):
        monkeypatch.setattr(
            mgr.store,
            "decrypt_row_secrets",
            lambda row: {"headers": {"Authorization": "Bearer t"}},
        )
        specs = mgr._specs_from_integrations(self._rows(), None)
        assert [s.slug for s in specs] == ["alpha", "beta"]  # oauth row skipped
        assert specs[0].headers == {"Authorization": "Bearer t"}
        assert specs[0].transport == "sse"

    def test_per_chat_enabled_integration_ids_filter(self, monkeypatch):
        monkeypatch.setattr(mgr.store, "decrypt_row_secrets", lambda row: {})
        specs = mgr._specs_from_integrations(
            self._rows(), {"enabled_integration_ids": ["int-2"]}
        )
        assert [s.slug for s in specs] == ["beta"]

    def test_legacy_fallback_requires_skills_enabled(self, monkeypatch):
        monkeypatch.setattr(mgr.store, "list_enabled_integrations", lambda sb, tid: [])
        settings = {
            "skills_enabled": False,
            "mcp_servers": [{"name": "Old", "url": "https://old.example.com"}],
        }
        assert mgr.load_server_specs("t1", settings, supabase=object()) == []
        settings["skills_enabled"] = True
        specs = mgr.load_server_specs("t1", settings, supabase=object())
        assert len(specs) == 1
        assert specs[0].slug == "old"


class TestExternalToolCap:
    @pytest.mark.asyncio
    async def test_cap_at_15(self, monkeypatch):
        specs = [_spec("a"), _spec("b")]

        async def fake_discover(spec, tenant_id):
            return [
                {"type": "function", "function": {"name": f"mcp__{spec.slug}__t{i}"}}
                for i in range(10)
            ]

        monkeypatch.setattr(mgr, "load_server_specs", lambda *a, **k: specs)
        monkeypatch.setattr(mgr, "discover_tools", fake_discover)
        tools = await mgr.get_external_tools("t1", None)
        assert len(tools) == mgr.MAX_EXTERNAL_TOOLS == 15
