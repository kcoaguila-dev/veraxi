"""
MCP Web Browser Tool using browser-use and Playwright.
Supports dynamic routing to BYOK Browserbase CDP endpoint or local headless browser.

browser-use 1.0 notes: BrowserProfile / Browser(config=...) were removed —
options are passed directly to Browser(...). LangChain chat models are also
rejected by Agent(...) in 1.0, so the LLM must be a browser_use.llm native
chat model; build_browser_llm() below performs that mapping from the same
(model, api_key, base_url) configuration the LiteLLM routing uses elsewhere.
"""

from __future__ import annotations

import logging
from typing import Any

from backend import context as byod_context

logger = logging.getLogger(__name__)


def build_browser_llm(model_name: str, api_key: str | None, base_url: str | None) -> Any:
    """Build a browser-use 1.0 native chat model from the configured LLM settings.

    Mirrors orchestrator._create_chat_llm's routing inputs: the model name is
    normalized the same way (LiteLLM provider prefix) before mapping. When a
    base URL is configured it is an OpenAI-compatible endpoint (e.g. a LiteLLM
    proxy) that routes the normalized model name itself, so ChatOpenAI is
    pointed at it unchanged. Without a base URL, the native provider client
    for the model's provider is used with the bare model name.
    """
    from browser_use.llm import ChatAnthropic, ChatGoogle, ChatOpenAI

    from backend.mcp_server.orchestrator import normalize_litellm_model

    normalized_model, final_base_url = normalize_litellm_model(model_name, base_url)

    key_kwargs: dict[str, Any] = {}
    if api_key:
        key_kwargs["api_key"] = api_key

    if final_base_url:
        return ChatOpenAI(
            model=normalized_model, base_url=final_base_url, **key_kwargs
        )
    if normalized_model.startswith("anthropic/"):
        return ChatAnthropic(
            model=normalized_model.removeprefix("anthropic/"), **key_kwargs
        )
    if normalized_model.startswith("gemini/"):
        return ChatGoogle(
            model=normalized_model.removeprefix("gemini/"), **key_kwargs
        )
    bare_model = (
        normalized_model.removeprefix("openai/")
        if normalized_model.startswith("openai/")
        else normalized_model
    )
    return ChatOpenAI(model=bare_model, **key_kwargs)


async def mcp_web_browser(task: str, llm: Any) -> dict[str, Any]:
    """Execute a task in a web browser.

    If context.request_browserbase_key has a key, it connects to Browserbase's CDP.
    Otherwise, it runs a local headless browser.

    ``llm`` must be a browser-use native chat model (see build_browser_llm);
    browser-use 1.0 rejects LangChain chat models in Agent(...).
    """
    try:
        from browser_use import Agent, Browser
    except ImportError:
        return {
            "status": "error",
            "error": "Browser automation dependencies are not installed. Install with: pip install 'veraxi-backend[browser]'",
        }

    browserbase_key = byod_context.request_browserbase_key.get()
    browser = None

    try:
        if browserbase_key:
            # Use Browserbase via remote CDP (browser-use 1.0 takes the CDP
            # endpoint directly; the remote browser manages headless itself)
            wss_url = "wss://connect.browserbase.com?apiKey=" + browserbase_key
            browser = Browser(cdp_url=wss_url)
        else:
            # Use local persistent headless browser (from AI_PROJECT).
            # browser-use 1.0 launches chromium with fixed flags (including
            # --no-sandbox in containers); the 0.x custom user_agent and args
            # options were removed upstream and cannot be passed anymore.
            browser = Browser(
                "chromium",
                headless=True,
                user_data_dir="/tmp/veraxi_browser_profile",
            )

        agent: Agent = Agent(task=task, llm=llm, browser=browser)

        result = await agent.run()
        return {"status": "success", "result": result.final_result()}

    except Exception as e:
        logger.error(f"Browser action failed: {e}")
        error_msg = str(e).lower()
        if not browserbase_key and (
            "cloudflare" in error_msg or "datadome" in error_msg or "bot" in error_msg
        ):
            return {
                "status": "error",
                "error": "Web page blocked by bot protection. Please configure a Browserbase API key in the Infrastructure panel to bypass this.",
            }
        return {"status": "error", "error": str(e)}
    finally:
        if browser:
            await browser.stop()
