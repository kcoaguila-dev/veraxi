# 4. Unified Multi-Provider and Local AI Thinking Levels

Date: 2026-11-24

## Status

Accepted

## Context

Veraxi supports frontier cloud models (OpenAI, Anthropic, Google Gemini, DeepSeek, Groq, Mistral, Moonshot/Kimi), self-hosted local HTTP servers (Ollama, llama.cpp, vLLM, LM Studio), and on-device GGUF inference (`fllama`). Each provider exposes incompatible reasoning controls (`reasoning_effort`, `thinking.type="adaptive"` + `effort`, `thinking.budget_tokens`, `thinking_level`, Ollama `think`, or Jinja `chat_template_kwargs.enable_thinking`) and distinct temperature constraints. Previously, `ChatLiteLLM` silently dropped top-level `reasoning_effort` kwargs, hardcoded `temperature=0`, routed Ollama through `ollama/` instead of `ollama_chat/`, and exposed a hardcoded `Low/Medium/High` menu only in Code Mode.

## Decision

1. **Backend Single Source of Truth (`backend/thinking_policy.py`)**: All provider capability rules, canonical-to-provider parameter translations, temperature policies, and local runtime probing (Ollama `/api/show`, llama.cpp `/props`) live in `backend/thinking_policy.py`.
2. **LiteLLM `model_kwargs` & `ollama_chat/` Routing**: `orchestrator.py` passes reasoning parameters via `ChatLiteLLM(model_kwargs=...)`, omits or adjusts `temperature` when thinking is active, routes Ollama via `ollama_chat/`, and uses **strict fail-fast** validation (`UnsupportedThinkingLevelError` → HTTP 400) rather than silently downgrading or overriding the user's explicit choice.
3. **Capability Discovery Endpoint (`GET /api/models/capabilities`)**: Exposes per-model supported levels and mode (`none`, `toggle`, `effort`, `adaptive_effort`, `level`, `budget`) to the frontend without breaking `GET /api/models`.
4. **Shared Model-Aware Flutter Selector & Per-Model Persistence**: `ThinkingLevelSelector` is shared across Chat Mode and Code Mode, filters options by model capability, hides for non-reasoning models, and persists preferences per model in `SharedPreferences`.
5. **Chunk-Safe Stream Parsing**: Both `backend/mcp_server/think_parser.py` and `app/lib/core/local_ai/think_tag_stream_parser.dart` buffer partial `<think>` / `<thought>` tag boundaries across streamed chunks.

## Consequences

- **Positive**: Thinking levels work reliably across cloud, self-hosted local, and on-device GGUF models; non-reasoning models never receive invalid parameters; UI stays clean and accurate.
- **Negative**: Switching Ollama normalization from `ollama/` to `ollama_chat/` required updating the prefix assertion in `backend/tests/test_api_models.py`.
