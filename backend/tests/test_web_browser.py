"""Tests for the browser-use 1.0 migration of the web_browser MCP tool.

browser-use is an optional extra ('browser'), so tests that need it skip
when it is not installed. They pin the 1.0 API surface the tool relies on:
Browser(...) flat options (no BrowserProfile / Browser(config=...)) and
browser_use.llm native chat models (Agent rejects LangChain models in 1.0).
"""

from __future__ import annotations

import asyncio
from typing import Any, ClassVar

import pytest

from backend.mcp_server.tools import web_browser


class _FakeHistory:
    def final_result(self) -> str:
        return "fake-result"


class _FakeBrowser:
    instances: ClassVar[list[_FakeBrowser]] = []

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        self.args = args
        self.kwargs = kwargs
        self.stopped = False
        _FakeBrowser.instances.append(self)

    async def stop(self) -> None:
        self.stopped = True


class _FakeAgent:
    instances: ClassVar[list[_FakeAgent]] = []

    def __init__(self, **kwargs: Any) -> None:
        self.kwargs = kwargs
        _FakeAgent.instances.append(self)

    async def run(self) -> _FakeHistory:
        return _FakeHistory()


@pytest.fixture(autouse=True)
def _reset_fakes() -> None:
    _FakeBrowser.instances.clear()
    _FakeAgent.instances.clear()


def _patch_browser_use(monkeypatch: pytest.MonkeyPatch) -> None:
    pytest.importorskip("browser_use")
    monkeypatch.setattr("browser_use.Browser", _FakeBrowser)
    monkeypatch.setattr("browser_use.Agent", _FakeAgent)


def test_local_browser_uses_1_0_flat_options(monkeypatch: pytest.MonkeyPatch) -> None:
    _patch_browser_use(monkeypatch)
    web_browser.byod_context.request_browserbase_key.set(None)

    result = asyncio.run(web_browser.mcp_web_browser("do a task", llm=object()))

    assert result == {"status": "success", "result": "fake-result"}
    browser = _FakeBrowser.instances[0]
    assert browser.args == ("chromium",)
    assert browser.kwargs["headless"] is True
    assert browser.kwargs["user_data_dir"] == "/tmp/veraxi_browser_profile"
    # Removed-in-1.0 options must not come back.
    assert "config" not in browser.kwargs
    assert "user_agent" not in browser.kwargs
    assert "args" not in browser.kwargs
    assert browser.stopped is True
    assert _FakeAgent.instances[0].kwargs["task"] == "do a task"


def test_browserbase_browser_uses_cdp_url(monkeypatch: pytest.MonkeyPatch) -> None:
    _patch_browser_use(monkeypatch)
    web_browser.byod_context.request_browserbase_key.set("bb-key")

    result = asyncio.run(web_browser.mcp_web_browser("do a task", llm=object()))

    assert result["status"] == "success"
    browser = _FakeBrowser.instances[0]
    expected_url = "wss://connect.browserbase.com?apiKey=" + "bb-key"
    assert browser.kwargs["cdp_url"] == expected_url


def test_build_browser_llm_prefers_base_url_endpoint() -> None:
    pytest.importorskip("browser_use")
    from browser_use.llm import ChatOpenAI

    llm = web_browser.build_browser_llm(
        "gpt-4o", "sk-test", "http://localhost:4000/v1"
    )
    assert isinstance(llm, ChatOpenAI)
    # normalize_litellm_model adds the provider prefix; the configured
    # OpenAI-compatible endpoint (LiteLLM proxy) routes that name itself.
    assert llm.model == "openai/gpt-4o"
    assert str(llm.base_url).rstrip("/") == "http://localhost:4000/v1"


def test_build_browser_llm_native_providers_without_base_url() -> None:
    pytest.importorskip("browser_use")
    from browser_use.llm import ChatAnthropic, ChatGoogle, ChatOpenAI

    anthropic_llm = web_browser.build_browser_llm(
        "anthropic/claude-sonnet-4-5", "sk-ant", None
    )
    assert isinstance(anthropic_llm, ChatAnthropic)
    assert anthropic_llm.model == "claude-sonnet-4-5"

    google_llm = web_browser.build_browser_llm("gemini/gemini-2.5-flash", "sk-g", None)
    assert isinstance(google_llm, ChatGoogle)

    openai_llm = web_browser.build_browser_llm("openai/gpt-4o", "sk-o", None)
    assert isinstance(openai_llm, ChatOpenAI)
    assert openai_llm.model == "gpt-4o"
