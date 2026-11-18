import asyncio
import json
import os
import sys

# Enable readline for terminal history and editing if available
try:
    import readline

    _ = readline
except ImportError:
    pass

from veraxi.cli.models import run_models_list
from veraxi.cli.query import run_query
from veraxi.cli.stats import run_stats
from veraxi.cli.trace import run_trace
from veraxi.cli.web import run_web


def _format_tool_input(args: dict) -> str:
    """Format tool parameters compactly for terminal display."""
    if not args:
        return "{}"
    parts = []
    for k, v in args.items():
        if isinstance(v, (int, float, bool)):
            parts.append(f"{k}={v}")
        else:
            v_str = str(v)
            if len(v_str) > 40:
                v_str = v_str[:37] + "..."
            parts.append(f"{k}={v_str!r}")
    return ", ".join(parts)


_LEG_BADGES = {"vector": "Vector", "sparse": "Sparse", "graph": "Graph"}

_LAST_SOURCES: list = []


def format_deep_estimate(estimate):
    """Format a POST /api/chat/estimate-deep response as one line."""
    if not isinstance(estimate, dict):
        return None
    total = estimate.get("total_tokens") or {}
    low, high = total.get("min"), total.get("max")
    if low is None or high is None:
        return None
    line = f"Deep mode est: {low}–{high} tokens"
    cost = estimate.get("estimated_cost_usd")
    if isinstance(cost, dict) and cost.get("min") is not None and cost.get("max") is not None:
        line += f" (${cost['min']:.2f}–${cost['max']:.2f})"
    return line


def fetch_deep_estimate(endpoint, key=None, tenant=None, model=None):
    """Fetch the Deep pre-flight estimate; None on any failure (never blocks chat)."""
    try:
        from veraxi.cli.http_client import api_request

        body = {"model": model} if model else {}
        return api_request(
            "POST", "/api/chat/estimate-deep", body=body, endpoint=endpoint, key=key, tenant=tenant,
            quiet=True,
        )
    except SystemExit:
        return None
    except Exception:
        return None


def print_deep_estimate(endpoint, key=None, tenant=None, model=None):
    """Print the Deep estimate line if available; silent no-op on failure."""
    line = format_deep_estimate(fetch_deep_estimate(endpoint, key, tenant, model))
    if line:
        print(line)
    return line


def _source_provenance(source):
    if not isinstance(source, dict):
        return None
    prov = source.get("provenance")
    if isinstance(prov, dict):
        return prov
    if any(k in source for k in ("legs", "fused_score", "graph_path")):
        return {
            "legs": source.get("legs") or [],
            "fused_score": source.get("fused_score"),
            "graph_path": source.get("graph_path"),
        }
    legs_src = source.get("sources")
    if isinstance(legs_src, list):
        legs = [leg for leg in ("vector", "sparse", "graph") if leg in legs_src]
        if legs:
            return {"legs": legs, "fused_score": source.get("fused_score"), "graph_path": None}
    return None


def format_provenance(sources):
    """Render per-source provenance: badges, fused_score, indented graph_path."""
    lines = []
    if not sources:
        return "No sources recorded for the last answer."
    for idx, source in enumerate(sources, 1):
        prov = _source_provenance(source)
        label = ""
        if isinstance(source, dict):
            label = source.get("title") or source.get("name") or source.get("id") or ""
        if prov is None:
            lines.append(f"{idx}. {label} (no provenance)".strip())
            continue
        badges = " ".join(f"[{_LEG_BADGES.get(leg, leg)}]" for leg in (prov.get("legs") or []))
        score = prov.get("fused_score")
        score_str = f" fused_score={score:.3f}" if isinstance(score, (int, float)) else ""
        lines.append(f"{idx}. {label} {badges}{score_str}".strip())
        graph_path = prov.get("graph_path")
        if isinstance(graph_path, list) and graph_path:
            steps = []
            for step in graph_path:
                if isinstance(step, dict):
                    node = step.get("node", "?")
                    rel = step.get("relation")
                    steps.append(f"{node} -[{rel}]->" if rel else str(node))
            if steps:
                lines.append(f"    graph_path: {' '.join(steps)}")
    return "\n".join(lines)


def print_provenance(sources, as_json=False):
    if as_json:
        raw = [_source_provenance(s) for s in (sources or [])]
        print(json.dumps(raw, indent=2))
        return
    print(format_provenance(sources))


def format_metrics_footer(metrics):
    """One-line footer from shaped metrics (formatter._finalize_metrics shape)."""
    if not isinstance(metrics, dict):
        return None
    gen_sec = metrics.get("generation_seconds") or metrics.get("total_seconds")
    parts = [f"Worked for {gen_sec}s" if gen_sec else "done"]
    prompt = metrics.get("prompt_tokens")
    completion = metrics.get("completion_tokens")
    total = metrics.get("total_tokens")
    if total is not None or prompt is not None or completion is not None:
        parts.append(f"tokens: prompt={prompt} completion={completion} total={total}")
    cost = metrics.get("estimated_cost_usd")
    if isinstance(cost, (int, float)):
        parts.append(f"cost: ${cost:.4f}")
    return " • ".join(parts)


def _render_event(event, state):
    """Render one stream event (single renderer for local and SSE paths)."""
    bold = "\033[1m"
    cyan = "\033[36m"
    green = "\033[32m"
    yellow = "\033[33m"
    dim = "\033[2m"
    italic = "\033[3m"
    reset = "\033[0m"
    evt_type = event.get("event")
    data = event.get("data", {}) if isinstance(event.get("data"), dict) else {}

    if evt_type == "on_step_start":
        step = event.get("step", 1)
        desc = event.get("description") or event.get("name", "Processing")
        print(f"\n{bold}{cyan}● Step {step}: {desc}{reset}")
    elif evt_type == "on_tool_start":
        name = event.get("name", "tool")
        label = event.get("label", name)
        inp = _format_tool_input(data.get("input", {}))
        print(f"  {yellow}⠋ Running tool: {bold}{label}{reset} {dim}({name}){reset}")
        print(f"    {dim}Parameters: {inp}{reset}")
    elif evt_type == "on_tool_end":
        name = event.get("name", "tool")
        label = event.get("label", name)
        dur = event.get("duration_ms")
        dur_str = f" • Worked for {dur}ms" if dur is not None else ""
        summary = event.get("summary", "Executed")
        status = event.get("status", "success")
        status_color = green if status == "success" else yellow
        print(f"  {status_color}✓ Completed: {bold}{label}{reset}{dim}{dur_str}{reset}")
        print(f"    {dim}Output: {summary}{reset}")
        artifact = data.get("artifact") or event.get("artifact")
        if isinstance(artifact, list) and artifact:
            state["sources"] = artifact
            _LAST_SOURCES.clear()
            _LAST_SOURCES.extend(artifact)
    elif evt_type == "on_reasoning_stream":
        text = data.get("text", "")
        if text:
            sys.stdout.write(f"{dim}{italic}{text}{reset}")
            sys.stdout.flush()
    elif evt_type == "on_reasoning_end":
        sec = data.get("seconds", 0.0)
        print(f"\n  {dim}{italic}Thought for {sec}s{reset}\n")
    elif evt_type == "on_chat_model_stream":
        chunk = data.get("chunk")
        content = None
        if isinstance(chunk, dict):
            content = chunk.get("content")
        elif chunk is not None and hasattr(chunk, "content"):
            content = chunk.content
        elif isinstance(data.get("content"), str):
            content = data.get("content")
        if content:
            if not state.get("has_started_answer"):
                print(f"\n{bold}{green}Answer:{reset}\n")
                state["has_started_answer"] = True
            sys.stdout.write(content)
            sys.stdout.flush()
    elif evt_type == "metadata":
        sources = data.get("sources") or data.get("artifacts") or event.get("sources")
        if isinstance(sources, list) and sources:
            state["sources"] = sources
            _LAST_SOURCES.clear()
            _LAST_SOURCES.extend(sources)
        metrics = data.get("metrics")
        footer = format_metrics_footer(metrics) if isinstance(metrics, dict) else None
        if footer:
            print(f"\n\n{dim}─── {footer} ───{reset}")
        if state.get("show_sources") and state.get("sources"):
            print_provenance(state["sources"], as_json=state.get("as_json", False))


def run_agent_stream(
    query: str,
    tenant_id: str = "default",
    endpoint: str = "http://127.0.0.1:8000",
    key: str | None = None,
    model: str | None = None,
    tool_settings: dict | None = None,
    mode: str = "fast",
    show_sources: bool = False,
    as_json: bool = False,
    dry_run: bool = False,
) -> bool:
    """
    Executes conversational query with real-time step and tool execution visibility.
    Emulates rival UX (Claude, AnythingLLM) by streaming steps, active tools,
    durations, and reasoning traces in real-time.

    Supports dual execution modes:
      - 'fast': Sub-second Hybrid GraphRAG (search_vectors, query_graph)
      - 'deep': Multi-Agent Debate Swarm (Vector, Graph, Web, Synthesizer, Skeptic)

    Returns True if streaming completed successfully, False otherwise.
    """
    bold = "\033[1m"
    cyan = "\033[36m"
    green = "\033[32m"
    yellow = "\033[33m"
    dim = "\033[2m"
    reset = "\033[0m"

    # Pre-flight Deep estimate (silent no-op on failure; never blocks chat).
    if mode == "deep":
        print_deep_estimate(endpoint, key, tenant_id, model)
        if dry_run:
            return True
    elif dry_run:
        return True

    # 1. Try local execution if running in Veraxi repo/host
    try:
        if mode == "deep":
            from backend.mcp_server.orchestrator_multi_agent import get_debate_workflow

            async def _local_deep_runner():
                print(f"\n{bold}{cyan}● Multi-Agent Deep Research Swarm Initialized{reset}")
                print(
                    f"  {dim}Collaborating: Vector + Graph + Web Specialists, Synthesizer, Writer, Skeptic{reset}\n"
                )

                workflow = get_debate_workflow()
                app = workflow.compile()
                initial_state = {
                    "query": query,
                    "tenant_id": tenant_id,
                    "tool_settings": tool_settings or {},
                    "iterations": 0,
                    "vector_data": "",
                    "graph_data": "",
                    "web_data": "",
                    "research_data": "",
                    "draft": "",
                    "critique": "",
                    "grounding_score": 1.0,
                    "is_approved": False,
                }

                final_draft = ""
                grounding_score = 1.0
                critique = ""
                is_approved = False

                async for event in app.astream(initial_state):
                    for node_name, node_output in event.items():
                        if node_name == "vector_specialist":
                            v_len = len(node_output.get("vector_data", ""))
                            print(
                                f"  {green}✓ Vector Specialist:{reset} Retrieved Qdrant vector chunks {dim}({v_len} chars){reset}"
                            )
                        elif node_name == "graph_specialist":
                            g_len = len(node_output.get("graph_data", ""))
                            print(
                                f"  {green}✓ Graph Specialist:{reset} Traversed Neo4j causal relationships {dim}({g_len} chars){reset}"
                            )
                        elif node_name == "web_specialist":
                            w_len = len(node_output.get("web_data", ""))
                            print(
                                f"  {green}✓ Web Specialist:{reset} Gathered live external data {dim}({w_len} chars){reset}"
                            )
                        elif node_name == "synthesizer":
                            print(
                                f"  {yellow}⠋ Synthesizer:{reset} Fused multi-source evidence matrix"
                            )
                        elif node_name == "writer":
                            final_draft = node_output.get("draft", "")
                            iter_num = node_output.get("iterations", 1)
                            print(
                                f"  {cyan}✎ Writer:{reset} Drafted synthesis report {dim}(iteration {iter_num}){reset}"
                            )
                        elif node_name == "skeptic":
                            grounding_score = node_output.get("grounding_score", 1.0)
                            is_approved = node_output.get("is_approved", True)
                            critique = node_output.get("critique", "")
                            status_str = (
                                f"{green}Approved{reset}"
                                if is_approved
                                else f"{yellow}Critique & Revise{reset}"
                            )
                            print(
                                f"  {bold}⚖ Skeptic Verifier:{reset} {status_str} {dim}(Grounding Score: {grounding_score:.2f}){reset}"
                            )
                            if critique and not is_approved:
                                print(f"    {dim}Critique: {critique[:80]}...{reset}")

                print(f"\n{bold}{green}Verified Deep Research Report:{reset}\n")
                print(final_draft or "No report produced.")
                print(
                    f"\n{dim}─── Grounding Score: {grounding_score:.2f} • 5-Agent Consensus ───{reset}\n"
                )
                return True

            return asyncio.run(_local_deep_runner())

        # Fast Mode (default)
        from backend.mcp_server.llm_loop import stream_answer_question

        async def _local_runner():
            state = {"has_started_answer": False, "sources": [], "show_sources": show_sources, "as_json": as_json}
            async for event in stream_answer_question(
                query,
                tenant_id=tenant_id,
                thread_id="cli-session",
                is_temporary=True,
                api_key_override=key,
                model_override=model,
                tool_settings=tool_settings,
            ):
                _render_event(event, state)

            if state.get("has_started_answer"):
                print()
            return True

        return asyncio.run(_local_runner())

    except (ImportError, RuntimeError, Exception):
        # If local runner fails or lacks LLM credentials, fall back to remote HTTP SSE or run_query
        pass

    # 2. Try remote SSE streaming over HTTP
    try:
        import urllib.request
        import urllib.error

        base = endpoint.rstrip("/")
        if base.endswith("/sse"):
            base = base[:-4]
        chat_url = f"{base}/api/chat"

        payload = {
            "question": query,
            "tenant_id": tenant_id,
            "stream": True,
            "is_temporary": True,
            "mode": mode,
        }
        if key:
            payload["api_key"] = key
        if model:
            payload["model"] = model
        if tool_settings is not None:
            payload["tool_settings"] = tool_settings

        req = urllib.request.Request(
            chat_url,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json", "Accept": "text/event-stream"},
            method="POST",
        )
        if key:
            req.add_header("Authorization", f"Bearer {key}")

        state = {"has_started_answer": False, "sources": [], "show_sources": show_sources, "as_json": as_json}
        with urllib.request.urlopen(req, timeout=30) as resp:
            for raw_line in resp:
                line = raw_line.decode("utf-8", errors="replace").strip()
                if not line.startswith("data: "):
                    continue
                data_str = line[6:].strip()
                if data_str == "[DONE]":
                    break
                try:
                    event = json.loads(data_str)
                except Exception:
                    continue
                _render_event(event, state)

            if state.get("has_started_answer"):
                print()
            return True

    except Exception:
        return False


def run_interactive_chat(
    tenant_id: str = "default",
    limit: int = 5,
    endpoint: str = "https://api.veraxi.me/sse",
    key: str | None = None,
    model: str | None = None,
    mode: str = "fast",
    show_sources: bool = False,
    as_json: bool = False,
    dry_run: bool = False,
):
    """
    Launches an interactive Terminal Knowledge Assistant REPL with full
    step and tool execution visibility (Claude/AnythingLLM parity).
    """
    cyan = "\033[36m"
    bold = "\033[1m"
    green = "\033[32m"
    yellow = "\033[33m"
    dim = "\033[2m"
    reset = "\033[0m"

    mode = mode.lower() if mode in ("fast", "deep") else "fast"

    print(
        f"\n{bold}{cyan}╔════════════════════════════════════════════════════════════════════╗{reset}"
    )
    print(
        f"{bold}{cyan}║           Veraxi Terminal Knowledge Assistant (v0.1.0)             ║{reset}"
    )
    print(
        f"{bold}{cyan}║   Two-Tier GraphRAG • Real-Time Step & Tool Streaming Engine       ║{reset}"
    )
    print(
        f"{bold}{cyan}╚════════════════════════════════════════════════════════════════════╝{reset}"
    )
    print(f"{dim}Tenant ID: {tenant_id} | Endpoint: {endpoint}{reset}")
    print(
        f"{dim}Commands: 'exit' or 'quit' to leave, '/mode' to switch modes, 'clear' to clear.{reset}\n"
    )

    tool_settings = {
        "file_search_enabled": True,
        "web_search": {"enabled": False},
        "run_code_enabled": False,
        "skills_enabled": False,
    }

    if dry_run:
        if mode == "deep":
            print_deep_estimate(endpoint, key, tenant_id, model)
        return

    if mode == "deep":
        print_deep_estimate(endpoint, key, tenant_id, model)

    while True:
        try:
            mode_tag = f"{green}fast{reset}" if mode == "fast" else f"{cyan}deep{reset}"
            prompt_str = f"{bold}veraxi{reset} [{mode_tag}]> "
            query_text = input(prompt_str).strip()

            if not query_text:
                continue

            if query_text.lower() in ("exit", "quit", "q"):
                print(f"{dim}Session ended.{reset}\n")
                break

            if query_text.lower() == "clear":
                os.system("clear" if os.name != "nt" else "cls")
                continue

            if query_text.lower() in ("help", "/help", "?"):
                print(f"\n{yellow}Available Commands & Shortcuts:{reset}")
                print(
                    "  <question>          - Query knowledge assistant with live step & tool streaming"
                )
                print(
                    "  /mode               - View active execution mode (fast vs deep)"
                )
                print(
                    "  /mode [fast|deep]   - Switch execution mode"
                )
                print(
                    "  /fast, /deep        - Quick shortcut to switch modes"
                )
                print(
                    "  /tools              - View and manage active tools (GraphRAG, Web, Code)"
                )
                print(
                    "  /tools [on|off]     - Toggle all tools (use 'off' for pure fast LLM without token burn)"
                )
                print(
                    "  /rag [on|off]       - Toggle Hybrid GraphRAG vector & graph search"
                )
                print("  /web [on|off]       - Toggle live web search tool")
                print("  /code [on|off]      - Toggle Python code interpreter")
                print("  /web <query>        - Run direct standalone web search")
                print("  /sources            - Show provenance for the last answer")
                print("  /fetch <url>        - Read clean Markdown from a web page")
                print(
                    "  /trace <entity>     - Trace multi-hop causal graph relationships"
                )
                print(
                    "  /stats              - Display knowledge graph counts & telemetry"
                )
                print(
                    "  /models             - List supported AI models & provider readiness"
                )
                print("  clear               - Clear the terminal screen")
                print("  exit / quit         - End this interactive session\n")
                continue

            if query_text.lower() in ("/mode", "mode"):
                mode_color = green if mode == "fast" else cyan
                print(f"\n{bold}Active Mode:{reset} {mode_color}{mode.upper()}{reset}")
                print("  • fast : Sub-second Hybrid GraphRAG retrieval (default)")
                print(
                    "  • deep : 5-Agent Research Swarm (Vector + Graph + Web + Synthesizer + Skeptic)"
                )
                print(
                    f"\n{dim}Switch via: /mode fast, /mode deep, /fast, /deep{reset}\n"
                )
                continue

            if query_text.lower() in ("/mode fast", "mode fast", "/fast"):
                mode = "fast"
                print(
                    f"{green}Switched to Fast Mode (Sub-second Hybrid GraphRAG).{reset}\n"
                )
                continue

            if query_text.lower() in (
                "/mode deep",
                "mode deep",
                "/mode research",
                "/deep",
                "/research",
            ):
                mode = "deep"
                print(
                    f"{cyan}Switched to Deep Research Mode (5-Agent Debate Swarm).{reset}\n"
                )
                print_deep_estimate(endpoint, key, tenant_id, model)
                continue

            if query_text.lower() in ("/tools", "tools"):
                rag_status = (
                    f"{green}ON{reset}"
                    if tool_settings.get("file_search_enabled")
                    else f"{dim}OFF{reset}"
                )
                web_status = (
                    f"{green}ON{reset}"
                    if tool_settings.get("web_search", {}).get("enabled")
                    else f"{dim}OFF{reset}"
                )
                code_status = (
                    f"{green}ON{reset}"
                    if tool_settings.get("run_code_enabled")
                    else f"{dim}OFF{reset}"
                )
                skills_status = (
                    f"{green}ON{reset}"
                    if tool_settings.get("skills_enabled")
                    else f"{dim}OFF{reset}"
                )
                print(f"\n{bold}Active Tool Configuration:{reset}")
                print(f"  • Hybrid GraphRAG (file_search) : {rag_status}")
                print(f"  • Live Web Search (web_search)  : {web_status}")
                print(f"  • Python Code Box (run_code)    : {code_status}")
                print(f"  • MCP Dynamic Skills (skills)   : {skills_status}")
                print(
                    f"\n{dim}Toggle via: /rag on|off, /web on|off, /code on|off, /tools on|off{reset}\n"
                )
                continue

            if query_text.lower() in ("/tools off", "tools off"):
                tool_settings["file_search_enabled"] = False
                tool_settings["web_search"] = {"enabled": False}
                tool_settings["run_code_enabled"] = False
                tool_settings["skills_enabled"] = False
                print(
                    f"{yellow}All tools disabled. Running in pure, ultra-fast LLM mode (zero token overhead).{reset}\n"
                )
                continue

            if query_text.lower() in ("/tools on", "tools on"):
                tool_settings["file_search_enabled"] = True
                tool_settings["web_search"] = {"enabled": True}
                tool_settings["run_code_enabled"] = True
                print(
                    f"{green}All primary tools enabled (GraphRAG, Web Search, Code Interpreter).{reset}\n"
                )
                continue

            if query_text.lower() in ("/rag on", "/rag 1"):
                tool_settings["file_search_enabled"] = True
                print(f"{green}GraphRAG enabled.{reset}\n")
                continue

            if query_text.lower() in ("/rag off", "/rag 0"):
                tool_settings["file_search_enabled"] = False
                print(f"{yellow}GraphRAG disabled.{reset}\n")
                continue

            if query_text.lower() in ("/web on", "/web 1"):
                tool_settings["web_search"] = {"enabled": True}
                print(f"{green}Live Web Search enabled.{reset}\n")
                continue

            if query_text.lower() in ("/web off", "/web 0"):
                tool_settings["web_search"] = {"enabled": False}
                print(f"{yellow}Live Web Search disabled.{reset}\n")
                continue

            if query_text.lower() in ("/code on", "/code 1"):
                tool_settings["run_code_enabled"] = True
                print(f"{green}Code Interpreter enabled.{reset}\n")
                continue

            if query_text.lower() in ("/code off", "/code 0"):
                tool_settings["run_code_enabled"] = False
                print(f"{yellow}Code Interpreter disabled.{reset}\n")
                continue

            if query_text.startswith("/web "):
                search_q = query_text[5:].strip()
                run_web(action="search", query_or_url=search_q, limit=limit)
                continue

            if query_text.startswith("/fetch "):
                fetch_url = query_text[7:].strip()
                run_web(action="fetch", query_or_url=fetch_url)
                continue

            if query_text.startswith("/trace "):
                entity_name = query_text[7:].strip()
                run_trace(
                    entity_name=entity_name,
                    tenant_id=tenant_id,
                    endpoint=endpoint,
                    key=key,
                )
                continue

            if query_text.lower() in ("/sources", "sources"):
                print_provenance(list(_LAST_SOURCES), as_json=as_json)
                continue

            if query_text.lower() in ("/stats", "stats"):
                run_stats(tenant_id=tenant_id, endpoint=endpoint, key=key)
                continue

            if query_text.lower() in ("/models", "/model", "models"):
                run_models_list()
                continue

            # Stream steps and tool calls live
            success = run_agent_stream(
                query=query_text,
                tenant_id=tenant_id,
                endpoint=endpoint,
                key=key,
                model=model,
                tool_settings=tool_settings,
                mode=mode,
                show_sources=show_sources,
                as_json=as_json,
            )

            # Fallback to direct dossier retrieval if streaming agent loop is not active
            if not success:
                print()
                fallback_result = run_query(
                    query_text,
                    as_json=False,
                    tenant_id=tenant_id,
                    limit=limit,
                    endpoint=endpoint,
                    key=key,
                )
                chunks = (fallback_result or {}).get("chunks") or []
                if chunks:
                    sources = [
                        {
                            "title": c.get("title", "Unknown"),
                            "fused_score": c.get("score"),
                            "legs": c.get("legs") or [],
                            "graph_path": c.get("graph_path"),
                        }
                        for c in chunks
                    ]
                    _LAST_SOURCES.clear()
                    _LAST_SOURCES.extend(sources)
                    if show_sources:
                        print_provenance(sources, as_json=as_json)
                print()

        except (KeyboardInterrupt, EOFError):
            print(f"\n{dim}Session interrupted. Exiting.{reset}\n")
            break
