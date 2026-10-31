"""Veraxi CLI Model Discovery & Selection.

Lists available LLM models per provider (OpenAI, Anthropic, Gemini, Groq, DeepSeek, Ollama),
detects active API credentials, and manages the active model selection.
"""

from __future__ import annotations

import json
import os
import sys

from veraxi.cli.config import load_cli_config, set_config_value

PROVIDER_KEY_VARS = {
    "OpenAI": ["OPENAI_API_KEY", "openai_api_key"],
    "Anthropic": ["ANTHROPIC_API_KEY", "anthropic_api_key"],
    "Google Gemini": ["GEMINI_API_KEY", "gemini_api_key", "LLM_API_KEY"],
    "Groq": ["GROQ_API_KEY", "groq_api_key"],
    "DeepSeek": ["DEEPSEEK_API_KEY", "deepseek_api_key"],
    "Ollama": [],  # Local, requires no API key
}


def _get_supported_models() -> dict[str, list[str]]:
    """Retrieves supported models from backend models_config or fallback mapping."""
    try:
        from backend.models_config import DEFAULT_PROVIDER_MODELS

        return DEFAULT_PROVIDER_MODELS
    except Exception:
        # Fallback catalog if backend is not in pythonpath
        return {
            "OpenAI": ["gpt-4o", "gpt-4o-mini", "o3-mini", "o1", "gpt-4-turbo"],
            "Anthropic": [
                "claude-3-7-sonnet-20250219",
                "claude-3-5-sonnet-latest",
                "claude-3-5-haiku-latest",
            ],
            "Google Gemini": ["gemini-2.0-flash", "gemini-1.5-pro", "gemini-1.5-flash"],
            "Groq": [
                "llama-3.3-70b-versatile",
                "llama-3.1-8b-instant",
                "mixtral-8x7b-32768",
            ],
            "DeepSeek": ["deepseek-chat", "deepseek-reasoner"],
            "Ollama": ["llama3:latest", "mistral:latest", "qwen2.5:latest"],
        }


def _is_provider_ready(provider: str, config: dict) -> bool:
    """Checks if API keys are configured for this provider."""
    var_names = PROVIDER_KEY_VARS.get(provider, [])
    if not var_names:
        return True  # Local Ollama is always considered ready

    for var in var_names:
        if os.environ.get(var) or config.get(var.lower()) or config.get(var):
            return True
    return False


def get_current_active_model() -> str:
    """Detects active default model from config or environment."""
    config = load_cli_config()
    return (
        config.get("default_model")
        or os.environ.get("LLM_MODEL_NAME")
        or "gemini-2.0-flash"
    )


def run_models_list(
    provider_filter: str | None = None,
    as_json: bool = False,
) -> None:
    """Lists supported AI providers and models."""
    catalog = _get_supported_models()
    config = load_cli_config()
    current_model = get_current_active_model()

    if provider_filter:
        provider_filter = provider_filter.strip().lower()
        matched = {k: v for k, v in catalog.items() if provider_filter in k.lower()}
        if not matched:
            print(
                f"Error: Unknown provider '{provider_filter}'. Available: {', '.join(catalog.keys())}",
                file=sys.stderr,
            )
            sys.exit(1)
        catalog = matched

    if as_json:
        result = {"current_model": current_model, "providers": {}}
        for prov, models in catalog.items():
            result["providers"][prov] = {
                "ready": _is_provider_ready(prov, config),
                "models": models,
            }
        print(json.dumps(result, indent=2))
        return

    cyan = "\033[36m"
    bold = "\033[1m"
    green = "\033[32m"
    yellow = "\033[33m"
    dim = "\033[2m"
    reset = "\033[0m"

    print(
        f"\n{bold}{cyan}╔════════════════════════════════════════════════════════════════════╗{reset}"
    )
    print(
        f"{bold}{cyan}║                 Veraxi Supported LLM Models Catalog                ║{reset}"
    )
    print(
        f"{bold}{cyan}╚════════════════════════════════════════════════════════════════════╝{reset}"
    )
    print(f"  Active Model: {bold}{green}{current_model}{reset}\n")

    for provider, models in catalog.items():
        is_ready = _is_provider_ready(provider, config)
        status_tag = (
            f"{green}[READY - KEY SET]{reset}"
            if is_ready
            else f"{yellow}[NO KEY CONFIGURED]{reset}"
        )
        print(f"  {bold}{provider:<16}{reset} {status_tag}")
        print("  " + "─" * 45)

        for m in models[:6]:  # Show top 6 per provider
            is_active = m == current_model
            prefix = f"  {green}▶ {bold}" if is_active else "    • "
            suffix = f" (active default){reset}" if is_active else ""
            print(f"{prefix}{m}{suffix}")

        if len(models) > 6:
            print(f"    {dim}... and {len(models) - 6} more models{reset}")
        print()

    print(f"  {dim}Tip: Switch active model with: vx models set <model_name>{reset}\n")


def run_models_set(model_name: str) -> None:
    """Sets the active default model."""
    if not model_name:
        print(
            "Error: Model name required. Example: vx models set claude-3-5-sonnet-latest",
            file=sys.stderr,
        )
        sys.exit(1)

    ok = set_config_value("default_model", model_name)
    if ok:
        print(f"✓ Active default model set to: {model_name}")
    else:
        sys.exit(1)
