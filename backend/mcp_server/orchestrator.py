import asyncio
import copy
import json
import logging
import os
import re
import time
import urllib.parse
import urllib.request
from collections.abc import Sequence
from contextvars import ContextVar
from typing import Annotated, Any, TypedDict

import litellm
import sentry_sdk
from langchain_core.messages import (
    AIMessage,
    BaseMessage,
    HumanMessage,
    SystemMessage,
    ToolMessage,
)
from langchain_litellm import ChatLiteLLM
from langgraph.graph import END, START, StateGraph
from langgraph.graph.message import add_messages
from pydantic import BaseModel, Field

from backend.config import get_config
from backend.mcp_server.formatter import (
    _finalize_metrics,
    _prepend_system_messages,
)
from backend.mcp_server.tool_dispatch import get_tools

logger = logging.getLogger(__name__)

_request_model: ContextVar[str | None] = ContextVar("_request_model", default=None)


def _sanitize_messages_for_provider(
    messages: Sequence[BaseMessage],
) -> list[BaseMessage]:
    sanitized = []
    for message in messages:
        message_copy = copy.deepcopy(message)
        message_copy.additional_kwargs.pop("reasoning_content", None)
        sanitized.append(message_copy)
    return sanitized


_THINK_BLOCK_RE = re.compile(r"<think>(.*?)</think>", re.DOTALL)


def _extract_think_block(response: AIMessage) -> None:
    """Move an inline ``<think>...</think>`` block into reasoning_content.

    Streaming (llm_loop.py) separates <think> blocks into reasoning events
    only while the answer is being generated, so without this the trace is
    lost for non-streamed responses and never reaches the persisted
    AIMessage. Storing it in additional_kwargs is safe for multi-turn
    replay: _sanitize_messages_for_provider and the ChatLiteLLM serializer
    both strip reasoning_content before messages are sent to a provider.
    """
    if response.additional_kwargs.get("reasoning_content"):
        return
    content = response.content
    if not isinstance(content, str) or "<think>" not in content:
        return
    match = _THINK_BLOCK_RE.search(content)
    if not match:
        return
    reasoning = match.group(1)
    if reasoning:
        response.additional_kwargs["reasoning_content"] = reasoning
    response.content = content[: match.start()] + content[match.end() :]


_request_api_key: ContextVar[str | None] = ContextVar("_request_api_key", default=None)
_request_base_url: ContextVar[str | None] = ContextVar(
    "_request_base_url", default=None
)


def normalize_litellm_model(
    model_name: str, base_url: str | None = None
) -> tuple[str, str | None]:
    """
    Ensures model names have the correct provider prefix required by LiteLLM.
    LiteLLM routes bare model names (like 'gemini-3.6-flash' or 'claude-3-5-sonnet')
    to Vertex AI or raises ProviderNotFound unless properly prefixed with 'gemini/',
    'anthropic/', etc.
    """
    if not model_name:
        return model_name, base_url

    from backend.models_config import DEFAULT_PROVIDER_MODELS

    if model_name in DEFAULT_PROVIDER_MODELS.get("groq", []):
        return f"groq/{model_name}", base_url

    known_prefixes = (
        "gemini/",
        "anthropic/",
        "deepseek/",
        "mistral/",
        "groq/",
        "moonshot/",
        "openai/",
        "ollama/",
        "openrouter/",
        "azure/",
        "bedrock/",
        "vertex_ai/",
    )
    if any(model_name.startswith(p) for p in known_prefixes):
        return model_name, base_url

    m = model_name.lower()

    if base_url:
        if "11434" in base_url or m.startswith("ollama"):
            return f"ollama/{model_name}", base_url
        return f"openai/{model_name}", base_url

    if m.startswith("gemini"):
        return f"gemini/{model_name}", None
    if m.startswith("claude"):
        return f"anthropic/{model_name}", None
    if m.startswith("deepseek"):
        return f"deepseek/{model_name}", None
    if m.startswith(("mistral", "codestral", "pixtral", "ministral", "devstral")):
        return f"mistral/{model_name}", None
    if m.startswith("moonshot"):
        return f"moonshot/{model_name}", None
    if m.startswith(("llama", "allam", "canopylabs", "meta-llama", "qwen", "groq")):
        if not model_name.startswith("groq/"):
            return f"groq/{model_name}", None
        return model_name, None
    if m.startswith(("gpt", "o1", "o3", "davinci", "babbage", "chatgpt")):
        return f"openai/{model_name}", None

    for provider, models in DEFAULT_PROVIDER_MODELS.items():
        if model_name in models:
            p = provider.lower()
            if p == "google":
                return f"gemini/{model_name}", None
            if p == "anthropic":
                return f"anthropic/{model_name}", None
            if p == "deepseek":
                return f"deepseek/{model_name}", None
            if p == "mistral":
                return f"mistral/{model_name}", None
            if p == "kimi":
                return f"moonshot/{model_name}", None
            if p == "groq":
                return f"groq/{model_name}", None
            if p == "openai":
                return f"openai/{model_name}", None

    return f"openai/{model_name}", base_url


_TOOL_GENERATION_ERROR_MARKERS = (
    "tool_use_failed",
    "failed_generation",
    "failed to call a function",
    "invalid tool call",
    "tool call validation",
)


def _is_tool_generation_error(exc: Exception) -> bool:
    """True if a provider 400 indicates the model emitted a malformed tool call."""
    text = str(exc).lower()
    return any(marker in text for marker in _TOOL_GENERATION_ERROR_MARKERS)


class _ReasoningStrippedChatLiteLLM(ChatLiteLLM):
    def _create_message_dicts(
        self, messages: list[BaseMessage], stop: list[str] | None
    ) -> tuple[list[dict[str, Any]], dict[str, Any]]:
        message_dicts, params = super()._create_message_dicts(messages, stop)
        for msg_dict in message_dicts:
            msg_dict.pop("reasoning_content", None)
        return message_dicts, params


def _create_chat_llm(model_name: str, api_key: str | None, base_url: str | None = None):
    """Build the configured chat LLM client via unified LiteLLM routing."""
    config = get_config()

    cfg_api_key = getattr(config, "llm_api_key", None)
    if not isinstance(cfg_api_key, str):
        cfg_api_key = None

    cfg_base_url = getattr(config, "llm_base_url", None)
    if not isinstance(cfg_base_url, str):
        cfg_base_url = None

    effective_api_key = api_key if isinstance(api_key, str) else cfg_api_key
    effective_base_url = base_url if isinstance(base_url, str) else cfg_base_url

    normalized_model, final_base_url = normalize_litellm_model(
        model_name, effective_base_url
    )

    llm_args: dict[str, Any] = {}
    if effective_api_key:
        llm_args["api_key"] = effective_api_key
    if final_base_url:
        llm_args["api_base"] = final_base_url

    # LiteLLM routing directly via ChatLiteLLM
    return _ReasoningStrippedChatLiteLLM(
        model=normalized_model,
        temperature=0,
        **llm_args,
    )


class AgentState(TypedDict):
    messages: Annotated[Sequence[BaseMessage], add_messages]
    tenant_id: str
    context_relevance: str
    retrieved_context: str
    query_embedding: list[float] | None
    calculate_grounding: bool
    tool_settings: dict | None


def _get_workflow():
    workflow = StateGraph(AgentState)
    workflow.add_node("agent", call_model)
    workflow.add_node("tools", execute_tools)
    workflow.add_node("evaluate", evaluate_context)
    workflow.add_node("web_search", web_search_fallback)

    workflow.add_edge(START, "agent")
    workflow.add_conditional_edges("agent", should_continue, ["tools", END])
    workflow.add_edge("tools", "evaluate")
    workflow.add_conditional_edges(
        "evaluate", route_evaluation, ["agent", "web_search"]
    )
    workflow.add_edge("web_search", "agent")

    return workflow


_CORE_BUILTIN_TOOLS = frozenset({
    "web_browser",
    "search_vectors",
    "query_graph",
    "create_office_artifact",
    "run_python_code",
})


def _integration_capability_note(tools_list: list) -> str | None:
    """Return a generic runtime note for any non-core integration tools."""
    names = [
        fn["name"]
        for t in tools_list
        if isinstance(t, dict)
        and isinstance(fn := t.get("function"), dict)
        and isinstance(fn.get("name"), str)
        and fn["name"] not in _CORE_BUILTIN_TOOLS
    ]
    if not names:
        return None
    joined = ", ".join(names)
    return (
        f"Connected external integration tools active in this chat: {joined}. "
        "When the user asks whether you have access to a connected service or "
        "requests data from it, call the relevant tool directly rather than "
        "claiming you lack access."
    )


def _append_system_note(messages: list, note: str) -> list:
    if messages and isinstance(messages[0], SystemMessage):
        updated = SystemMessage(content=f"{messages[0].content}\n\n{note}")
        return [updated, *messages[1:]]
    return [SystemMessage(content=note), *messages]


_OFFICE_ARTIFACT_FORMATS = ("pdf", "docx", "xlsx", "pptx")

_SLIDE_INTENT_EXPLICIT_RE = re.compile(r"\b(slide deck|pptx|powerpoint)\b")
_SLIDE_INTENT_CREATE_RE = re.compile(
    r"\b(create|make|build|generate|prepare|draft|design|give me|show me)\b"
    r"[^.?!]{0,80}\b(slides?|presentation)\b"
)

_SLIDE_DIRECTIVE = (
    "HIGH PRIORITY: The user is asking for a slide deck / presentation. "
    "You MUST call the create_office_artifact tool with format=\"pptx\" "
    "and a structured slides spec (one entry per slide, each with a "
    "title, optional subtitle/bullets, a theme of \"dark\" or \"light\", "
    "and an accent_color). Do not write the slides as prose, Markdown "
    "headings, HTML, or Reveal.js instead."
)


def _latest_human_text(messages: Sequence[BaseMessage]) -> str:
    for message in reversed(messages):
        is_human = getattr(message, "type", "") in ("human", "user") or (
            message.__class__.__name__ == "HumanMessage"
        )
        if is_human and isinstance(message.content, str):
            return message.content
    return ""


def _detect_office_artifact_intent(messages: Sequence[BaseMessage]) -> str | None:
    """Return ``"pptx"`` when the latest user message asks for slides.

    Intent is deliberately narrow: an explicit deck format/name
    (``slide deck``, ``pptx``, ``PowerPoint``) or a creation verb near
    ``slide``/``presentation``. Questions *about* slides do not match,
    so ordinary chat never gets a forced tool directive.
    """
    text = _latest_human_text(messages).lower()
    if not text:
        return None
    if _SLIDE_INTENT_CREATE_RE.search(text):
        return "pptx"
    question_like = "?" in text or text.startswith(
        ("what", "how", "why", "when", "explain", "tell me about")
    )
    if not question_like and _SLIDE_INTENT_EXPLICIT_RE.search(text):
        return "pptx"
    return None


def _tool_names(tools_list: list) -> set[str]:
    names: set[str] = set()
    for tool in tools_list:
        if not isinstance(tool, dict):
            continue
        fn = tool.get("function")
        if isinstance(fn, dict) and isinstance(fn.get("name"), str):
            names.add(fn["name"])
    return names


_FENCED_JSON_RE = re.compile(r"```json\s*\n(.*?)\n```", re.DOTALL)


def _is_office_envelope(obj: Any) -> bool:
    if not isinstance(obj, dict):
        return False
    if obj.get("format") not in _OFFICE_ARTIFACT_FORMATS:
        return False
    return any(key in obj for key in ("slides", "sheets", "sections", "content"))


def _office_envelope_from_block(block: str) -> dict | None:
    match = _FENCED_JSON_RE.fullmatch(block.strip())
    if not match:
        return None
    try:
        obj = json.loads(match.group(1))
    except (ValueError, TypeError):
        return None
    return obj if _is_office_envelope(obj) else None


def _blocks_from_artifact_payload(artifact: Any) -> list[str]:
    blocks: list[str] = []
    if not isinstance(artifact, (list, tuple)):
        return blocks
    for entry in artifact:
        if not isinstance(entry, dict):
            continue
        payload = entry.get("payload")
        if isinstance(payload, dict):
            block = payload.get("artifact_block")
            if isinstance(block, str) and _office_envelope_from_block(block):
                blocks.append(block)
    return blocks


def _blocks_from_content(content: Any) -> list[str]:
    if not isinstance(content, str):
        return []
    blocks: list[str] = []
    for match in _FENCED_JSON_RE.finditer(content):
        block = match.group(0)
        if _office_envelope_from_block(block):
            blocks.append(block)
    return blocks


def _extract_office_artifact_blocks(messages: Sequence[BaseMessage]) -> list[str]:
    """Exact ```json blocks produced by create_office_artifact this turn.

    The canonical source is the ToolMessage artifact payload, which
    carries the block verbatim; message content is a fallback for
    transports that flatten the payload into text.
    """
    blocks: list[str] = []
    for message in messages:
        candidates = _blocks_from_artifact_payload(
            getattr(message, "artifact", None)
        ) + _blocks_from_content(getattr(message, "content", None))
        for block in candidates:
            if block not in blocks:
                blocks.append(block)
    return blocks


def _strip_office_envelope_blocks(content: str, keep: str) -> str:
    def _replace(match: re.Match) -> str:
        block = match.group(0)
        if block == keep or not _office_envelope_from_block(block):
            return block
        return ""

    return _FENCED_JSON_RE.sub(_replace, content).strip()


def _envelope_slide_titles(block: str) -> list[str]:
    envelope = _office_envelope_from_block(block)
    if not envelope:
        return []
    slides = envelope.get("slides")
    if not isinstance(slides, list):
        return []
    return [
        str(slide["title"])
        for slide in slides
        if isinstance(slide, dict) and slide.get("title")
    ]


def _deck_ready_summary(titles: list[str]) -> str:
    listed = ", ".join(
        f"slide {i} says '{title}'" for i, title in enumerate(titles, 1)
    )
    return f"Your {len(titles)}-slide deck is ready: {listed}."


def _ensure_office_artifact_blocks(content: str, blocks: list[str]) -> str:
    """Deterministically attach tool-produced blocks to the final reply.

    The LLM only has to write the summary: a block it omitted is
    appended verbatim, a block it altered (a different office envelope)
    is replaced by the exact tool output, and a prose slide outline is
    collapsed to a concise deck-ready summary so the chat does not
    show the deck twice (once as prose, once as the artifact card).
    """
    result = content
    for block in blocks:
        if block in result:
            continue
        result = _strip_office_envelope_blocks(result, keep=block)
        titles = _envelope_slide_titles(block)
        if titles and _parse_markdown_slides(result):
            result = _deck_ready_summary(titles)
        result = f"{result.rstrip()}\n\n{block}" if result.strip() else block
    return result


_SLIDE_HEADING_RE = re.compile(
    r"^\s{0,3}(?:#{1,6}\s*)?(?:\*\*)?slide\s+(\d+)\s*(?:\*\*)?"
    r"\s*(?:[:.\-–—]\s*)?(.*)$",
    re.IGNORECASE,
)
_BULLET_RE = re.compile(r"^\s*(?:[-*•]|\d+[.)])\s+(.*)$")


def _parse_markdown_slides(content: str) -> list[dict] | None:
    """Parse ``Slide 1: …`` style prose into a slides spec, or None.

    Requires at least two slide headings — a single heading is an
    ordinary document outline, not a deck the model forgot to build.
    """
    segments: list[tuple[str, list[str]]] = []
    current: tuple[str, list[str]] | None = None
    for line in content.splitlines():
        heading = _SLIDE_HEADING_RE.match(line)
        if heading:
            current = (heading.group(2).strip(), [])
            segments.append(current)
            continue
        if current is None:
            continue
        text = line.strip().strip("*").strip()
        if not text:
            continue
        bullet = _BULLET_RE.match(line)
        current[1].append(bullet.group(1).strip() if bullet else text)
    if len(segments) < 2:
        return None
    slides: list[dict] = []
    for title, lines in segments:
        if not title and lines:
            title, lines = lines[0], lines[1:]
        if not title:
            return None
        slide: dict[str, Any] = {"title": title}
        if lines:
            slide["bullets"] = lines
        slides.append(slide)
    return slides


def _build_markdown_slide_block(content: str) -> str | None:
    """Safety net: build the pptx block for prose slides, or None."""
    slides = _parse_markdown_slides(content)
    if not slides:
        return None
    from backend.mcp_server.tool_dispatch import _build_office_artifact

    result = _build_office_artifact(
        {"format": "pptx", "title": "Presentation", "spec": {"slides": slides}}
    )
    block = result.get("block")
    return block if isinstance(block, str) else None


def _apply_deterministic_artifact_delivery(
    response: AIMessage, messages: Sequence[BaseMessage]
) -> None:
    """Guarantee the final AIMessage carries a valid artifact block."""
    if not isinstance(response.content, str):
        return
    if getattr(response, "tool_calls", None):
        return
    blocks = _extract_office_artifact_blocks(messages)
    if blocks:
        response.content = _ensure_office_artifact_blocks(response.content, blocks)
        return
    fallback_block = _build_markdown_slide_block(response.content)
    if fallback_block:
        titles = _envelope_slide_titles(fallback_block)
        summary = _deck_ready_summary(titles) if titles else "Your deck is ready."
        response.content = f"{summary}\n\n{fallback_block}"


async def call_model(state: AgentState):
    """The AI Agent node that decides what to do."""
    messages = state["messages"]
    started_at = time.perf_counter()

    config = get_config()

    effective_model = _request_model.get() or config.llm_model_name

    # Inherit base args (including the gemini url injection if applicable)
    config.get_llm_client_args(model_name=effective_model)

    # Prefer a per-request key (set by the caller via _request_api_key contextvar)
    # over the server-wide LLM_API_KEY so users can supply their own key via the UI.
    effective_api_key = _request_api_key.get() or config.llm_api_key
    effective_base_url = _request_base_url.get() or None
    llm = _create_chat_llm(effective_model, effective_api_key, effective_base_url)

    # Check if artifacts are enabled to inject system prompt
    tool_settings = state.get("tool_settings") or {}
    artifacts_enabled = tool_settings.get("artifacts_enabled", False)

    extra_system_messages: list[SystemMessage] = []
    if artifacts_enabled:
        extra_system_messages.append(
            SystemMessage(
                content=(
                    "Artifacts are enabled. For documents, slide decks / "
                    "presentations, spreadsheets, and PDFs you MUST call "
                    "the create_office_artifact tool (format=\"pptx\" with "
                    "a slides spec for decks) — never emit those as raw "
                    "fenced blocks or prose outlines. Reserve raw fenced "
                    "blocks for UI, code, and diagrams only, e.g. "
                    "```html\n<h1>Hello</h1>\n``` or ```mermaid\ngraph TD; A-->B;\n```. "
                    "Make sure your artifacts are entirely self-contained."
                )
            )
        )

    file_search_enabled = tool_settings.get("file_search_enabled", False)
    web_search = tool_settings.get("web_search", {})
    web_enabled = (
        web_search.get("enabled", False) if isinstance(web_search, dict) else False
    )
    if file_search_enabled or web_enabled:
        extra_system_messages.append(
            SystemMessage(
                content=(
                    "CITATION & GROUNDING RULES:\n"
                    "1. When information is retrieved from tools (such as web search, vector search, or knowledge graph), "
                    "ground your statements with inline bracketed citations [1], [2], or [Source Title] immediately after "
                    "the corresponding claim (like Perplexity).\n"
                    "2. ANTI-ATTRIBUTION-DRIFT: In multi-turn conversations and follow-up questions, NEVER reuse citations "
                    "from previous turns to justify new claims. If a follow-up question introduces new entities or questions "
                    "not answered by prior tool outputs, you MUST call the retrieval tools again for fresh context.\n"
                    "3. DO NOT make up URLs or cite materials not retrieved by tools for the current claim."
                )
            )
        )

    custom_system_prompt = tool_settings.get("custom_system_prompt")
    modified_messages = _prepend_system_messages(
        messages,
        extra_system_messages,
        custom_system_prompt=custom_system_prompt,
    )
    modified_messages = _sanitize_messages_for_provider(modified_messages)

    # Determine if we should bind tools. We do not bind tools if we are executing a fallback,
    # OR if we just received a ToolMessage (to prevent the LLM from hallucinating more tool calls and looping).
    last_msg = messages[-1]
    is_fallback = getattr(
        last_msg, "type", ""
    ) == "human" and "Web Search Fallback Context" in str(last_msg.content)
    is_after_tool = (
        getattr(last_msg, "type", "") == "tool"
        or last_msg.__class__.__name__ == "ToolMessage"
    )

    if is_fallback or is_after_tool:
        llm_with_tools = llm
    else:
        tools_list = await get_tools(tool_settings, tenant_id=state.get("tenant_id"))
        if tools_list:
            note = _integration_capability_note(tools_list)
            if note:
                modified_messages = _append_system_note(modified_messages, note)
            # Smaller models reliably miss create_office_artifact for
            # slide requests without a direct, high-priority nudge.
            if _detect_office_artifact_intent(messages) and (
                "create_office_artifact" in _tool_names(tools_list)
            ):
                modified_messages = _append_system_note(
                    modified_messages, _SLIDE_DIRECTIVE
                )
            llm_with_tools = llm.bind_tools(tools_list, parallel_tool_calls=True)
        else:
            llm_with_tools = llm

    MAX_RETRIES = 3
    response = None
    for attempt in range(MAX_RETRIES):
        try:
            response = await llm_with_tools.ainvoke(modified_messages)
            break
        except Exception as e:
            import logging

            if isinstance(e, litellm.exceptions.BadRequestError) and not (
                llm_with_tools is not llm and _is_tool_generation_error(e)
            ):
                # Not a malformed tool call: retrying cannot fix it.
                raise

            logging.getLogger(__name__).warning(
                f"Tool invocation crashed (Attempt {attempt + 1}/{MAX_RETRIES}) for {effective_model}: {e}"
            )
            if attempt < MAX_RETRIES - 1:
                # Add the error to the context so the model can try to correct itself
                modified_messages.append(
                    AIMessage(
                        content="[I attempted to use a tool but generated invalid syntax.]"
                    )
                )
                modified_messages.append(
                    HumanMessage(
                        content=f"Your previous tool call failed with error: {e}. Please strictly follow the required JSON tool call format and try again."
                    )
                )
            else:
                logging.getLogger(__name__).warning(
                    "Max retries reached. Falling back to llm without tools."
                )
                response = await llm.ainvoke(modified_messages)
                break

    if not response:
        raise RuntimeError("Failed to get response from LLM")

    # Persist any inline <think> reasoning on the message itself so it
    # survives history reads / web reloads, not just live streaming.
    _extract_think_block(response)

    # Artifact delivery must not depend on the LLM copy-pasting the
    # create_office_artifact block back verbatim: re-attach the exact
    # tool block (or build one from prose slides) deterministically.
    _apply_deterministic_artifact_delivery(response, messages)

    # Inject the model name into the response so it gets saved to history and sent to frontend
    response.additional_kwargs["model_name"] = effective_model

    metrics: dict[str, Any] = {
        "generation_seconds": round(time.perf_counter() - started_at, 3),
        # Pass embeddings into metrics so _finalize_metrics can compute cosine retrieval_relevance.
        # These are popped inside _finalize_metrics and never sent to the frontend.
        "query_embedding": state.get("query_embedding"),
        "context_embedding": state.get("context_embedding"),
    }
    if state.get("calculate_grounding"):
        from backend.evaluation.grounding import evaluate_groundedness

        grounding_score = evaluate_groundedness(
            response.content,
            state.get("retrieved_context", ""),
            api_key=effective_api_key,
            model_name=effective_model,
        )
        metrics["grounding_score"] = (
            round(grounding_score, 3) if grounding_score is not None else None
        )

    response.additional_kwargs["metrics"] = _finalize_metrics(metrics)
    return {"messages": [response]}


async def execute_tools(state: AgentState):
    """The Tool execution node that runs DB queries and merges them."""
    from backend.mcp_server.tool_dispatch import execute_tools_internal

    messages = state["messages"]
    tenant_id = state["tenant_id"]

    last_message = messages[-1]
    tool_calls = getattr(last_message, "tool_calls", [])
    tool_messages = []

    context_str, merged = await execute_tools_internal(
        tool_calls, tenant_id, state.get("tool_settings") or {}
    )

    query_emb = None
    context_emb = None
    if state.get("calculate_grounding"):
        from backend.ingestion.chunk_embed import embed_text as _embed_text

        user_query = next(
            (
                m.content
                for m in reversed(messages)
                if getattr(m, "type", "") in ("human", "user")
                or m.__class__.__name__ == "HumanMessage"
            ),
            "",
        )
        try:
            loop = asyncio.get_running_loop()
            query_emb = (
                await loop.run_in_executor(None, _embed_text, user_query)
                if user_query
                else None
            )
            context_emb = (
                await loop.run_in_executor(None, _embed_text, context_str)
                if context_str and context_str != "No results found."
                else None
            )
        except Exception as e:
            logger.warning("Failed to generate embedding for context: %s", repr(e))
            import sentry_sdk

            sentry_sdk.capture_exception(e)

    for tool_call in tool_calls:
        tool_messages.append(
            ToolMessage(
                content=f"Here is the context retrieved from the database:\\n{context_str}\\n\\n",
                tool_call_id=tool_call["id"],
                artifact=[
                    {
                        "id": getattr(h, "id", ""),
                        "payload": getattr(h, "payload", {}),
                        "sources": getattr(h, "sources", []),
                    }
                    for h in merged
                ],
            )
        )

    return {
        "messages": tool_messages,
        "retrieved_context": context_str,
        "query_embedding": query_emb,
        "context_embedding": context_emb,
    }


def should_continue(state: AgentState) -> str:
    """Router that determines if we need to call tools or if we are done."""
    messages = state["messages"]
    last_message = messages[-1]

    # If the LLM made a tool call, route to tools
    if getattr(last_message, "tool_calls", []):
        return "tools"

    # Otherwise, we are done
    return END


def _apply_observability_settings(tool_settings: dict | None):
    if not tool_settings:
        return

    obs = tool_settings.get("observability", {})
    enabled = obs.get("langsmith_enabled", False)
    api_key = obs.get("langsmith_api_key", "")

    if enabled and api_key:
        if os.environ.get("LANGCHAIN_TRACING_V2") != "true":
            os.environ["LANGCHAIN_TRACING_V2"] = "true"
        if os.environ.get("LANGCHAIN_API_KEY") != api_key:
            os.environ["LANGCHAIN_API_KEY"] = api_key
        if os.environ.get("LANGCHAIN_PROJECT") != "Veraxi":
            os.environ["LANGCHAIN_PROJECT"] = "Veraxi"
    else:
        if os.environ.get("LANGCHAIN_TRACING_V2") != "false":
            os.environ["LANGCHAIN_TRACING_V2"] = "false"


def route_evaluation(state: AgentState) -> str:
    """Routes based on the evaluation grade."""
    score = state.get("context_relevance", "yes")
    if score == "yes":
        return "agent"
    return "web_search"


async def web_search_fallback(state: AgentState):
    """Fallback node that triggers SearXNG if the database context is insufficient."""
    logger.info("CRAG: Triggering Web Search Fallback via SearXNG...")
    messages = state["messages"]
    user_query = next(
        (
            m.content
            for m in reversed(messages)
            if getattr(m, "type", "") == "human"
            or getattr(m, "type", "") == "user"
            or m.__class__.__name__ == "HumanMessage"
        ),
        messages[0].content,
    )

    config = get_config()
    search_url = config.searxng_url

    # Apply override from tool_settings if available
    tool_settings = state.get("tool_settings") or {}
    web_settings = tool_settings.get("web_search") or {}
    if web_settings.get("provider") == "SearXNG" and web_settings.get("searxng_url"):
        search_url = web_settings.get("searxng_url")

    try:
        # Perform asynchronous web search in thread
        loop = asyncio.get_running_loop()

        def _do_search():
            req = urllib.request.Request(
                f"{search_url}?q={urllib.parse.quote(user_query)}&format=json&language=all",
                headers={"User-Agent": "VeraxiAgent/1.0"},
            )
            with urllib.request.urlopen(req) as response:
                return json.loads(response.read().decode())

        data = await loop.run_in_executor(None, _do_search)

        results = data.get("results", [])
        web_context = []
        for i, res in enumerate(results[:10], 1):  # Top 10 hits
            web_context.append(
                f"[Web Result {i} ({res.get('url')})]: {res.get('content')}"
            )

        context_str = "\n".join(web_context)
        if not context_str:
            context_str = "No web search results found."

        grounding_message = HumanMessage(
            content=(
                f"Web Search Fallback Context:\n{context_str}\n\n"
                f"Please provide your final answer based strictly on the above context."
            )
        )
        return {"messages": [grounding_message], "retrieved_context": context_str}
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error(f"CRAG Web Search failed: {e}")
        return {
            "messages": [
                HumanMessage(
                    content="Web search fallback failed. Please provide your final answer based on your internal knowledge or admit lack of context."
                )
            ]
        }


class GradeDocuments(BaseModel):
    """Binary score for relevance check on retrieved documents."""

    binary_score: str = Field(
        description="Documents are relevant to the question, 'yes' or 'no'"
    )


async def evaluate_context(state: AgentState):
    """Grades the context retrieved by tools against the user's query."""
    messages = state["messages"]

    # Find the most recent human query
    user_query = next(
        (
            m.content
            for m in reversed(messages)
            if getattr(m, "type", "") == "human"
            or getattr(m, "type", "") == "user"
            or m.__class__.__name__ == "HumanMessage"
        ),
        messages[0].content,
    )

    context_str = state.get("retrieved_context", "")

    # If the DB returned nothing or is empty
    if not context_str or "No results found." in context_str:
        logger.info("CRAG: No DB results found. Grading as irrelevant.")
        return {"context_relevance": "no"}

    # Short-circuit if only non-retrieval tools were called (e.g. code runner, time, external MCP)
    last_aimsg = next(
        (m for m in reversed(messages) if hasattr(m, "tool_calls") and m.tool_calls),
        None,
    )
    called_tool_names = (
        {tc.get("name") for tc in last_aimsg.tool_calls} if last_aimsg else set()
    )
    retrieval_tool_names = {
        "search_vectors",
        "query_graph",
        "mcp_search_vectors",
        "mcp_query_graph",
        "mcp_merge_rank",
    }
    if called_tool_names and not (called_tool_names & retrieval_tool_names):
        logger.info(
            "CRAG: Non-retrieval tools invoked. Skipping document relevance grading."
        )
        return {"context_relevance": "yes"}

    logger.info("CRAG: Evaluating retrieved context...")

    config = get_config()

    effective_model = _request_model.get() or config.llm_model_name
    effective_api_key = _request_api_key.get() or config.llm_api_key
    effective_base_url = _request_base_url.get() or None

    llm = _create_chat_llm(effective_model, effective_api_key, effective_base_url)
    structured_llm_grader = llm.with_structured_output(
        GradeDocuments, method="function_calling"
    ).with_config(tags=["crag_evaluator"])

    system = """You are a grader assessing relevance of a retrieved document to a user question. \n 
    It does not need to be a stringent test. The goal is to filter out erroneous retrievals. \n
    If the document contains keyword(s) or semantic meaning related to the user question, grade it as relevant. \n
    Give a binary score 'yes' or 'no' score to indicate whether the document is relevant to the question."""

    grade_prompt = f"{system}\n\nRetrieved document: \n\n {context_str} \n\n User question: {user_query}"

    try:
        res = await structured_llm_grader.ainvoke(grade_prompt)
        score = getattr(res, "binary_score", "no")
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error(f"CRAG Evaluation failed: {e}. Defaulting to 'no'.")
        score = "no"

    logger.info(f"CRAG: Graded context relevance as '{score}'")
    return {"context_relevance": score}
