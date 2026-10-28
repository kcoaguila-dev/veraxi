"""
MCP Web Browser Tool using browser-use and Playwright.
Supports dynamic routing to BYOK Browserbase CDP endpoint or local headless browser.
"""

from __future__ import annotations

import logging
from typing import Any

from browser_use import Agent, Browser, BrowserProfile

from backend import context as byod_context

logger = logging.getLogger(__name__)


async def mcp_web_browser(task: str, llm: Any) -> dict[str, Any]:
    """Execute a task in a web browser.

    If context.request_browserbase_key has a key, it connects to Browserbase's CDP.
    Otherwise, it runs a local headless browser.
    """
    browserbase_key = byod_context.request_browserbase_key.get()
    browser = None

    try:
        if browserbase_key:
            # Use Browserbase via remote CDP
            wss_url = f"wss://connect.browserbase.com?apiKey={browserbase_key}"
            config = BrowserProfile(
                wss_url=wss_url,  # type: ignore[call-arg]
                headless=True,
            )
            browser = Browser(config=config)  # type: ignore[call-arg, call-overload]
        else:
            # Use local persistent headless browser with anti-automation flags (from AI_PROJECT)
            config = BrowserProfile(
                headless=True,
                user_data_dir="/tmp/veraxi_browser_profile",
                user_agent=(
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/124.0.0.0 Safari/537.36"
                ),
                args=[
                    "--disable-blink-features=AutomationControlled",
                    "--no-sandbox",
                    "--disable-dev-shm-usage",
                ],
            )
            browser = Browser(config=config)  # type: ignore[call-arg, call-overload]

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
