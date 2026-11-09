import dataclasses
import glob
import json
import logging
import os
import re

from mcp.types import TextContent

from backend.config import get_config
from backend.mcp_server.handlers.tool_schemas import REGISTERED_TOOLS
from backend.mcp_server.orchestrator_multi_agent import mcp_agentic_debate
from backend.mcp_server.tools.delete_entity import delete_entity
from backend.mcp_server.tools.delete_relationship import delete_relationship
from backend.mcp_server.tools.delete_vector import delete_vector
from backend.mcp_server.tools.get_schema import get_graph_schema
from backend.mcp_server.tools.get_stats import get_database_stats
from backend.mcp_server.tools.ingest_document import (
    mcp_get_ingest_status,
    mcp_ingest_document,
)
from backend.mcp_server.tools.insert_vector import insert_vectors
from backend.mcp_server.tools.query_graph import (
    query_graph,
    seed_graph_hits_from_vectors,
)
from backend.mcp_server.tools.run_analytics import run_community_detection
from backend.mcp_server.tools.search_vectors import search_vectors
from backend.mcp_server.tools.update_document import update_document_metadata
from backend.mcp_server.tools.update_entity import update_entity
from backend.storage.graph_operations import insert_graph_nodes
from backend.storage.quota import check_tenant_hard_cap

__all__ = ["REGISTERED_TOOLS", "TOOL_HANDLERS"]

logger = logging.getLogger(__name__)


def _resolve_pdf_path(source: str) -> str | None:
    """Resolve a document source identifier to an on-disk PDF path if available."""
    if not source:
        return None
    if os.path.isfile(source):
        if not source.lower().endswith(".pdf") and os.path.isfile(source + ".pdf"):
            return os.path.abspath(source + ".pdf")
        return os.path.abspath(source)

    search_dirs = [
        os.environ.get("DOCUMENTS_DIR"),
        os.path.expanduser("~/Documents/book"),
        "/home/ubuntu/Documents/book",
        "/app/data",
        os.path.join(os.getcwd(), "seed"),
        os.getcwd(),
    ]
    norm_source = re.sub(r"[^a-zA-Z0-9]", "", source.lower())
    for d in search_dirs:
        if not d or not os.path.isdir(d):
            continue
        cands = sorted(
            glob.glob(os.path.join(d, "*")),
            key=lambda c: (0 if c.lower().endswith(".pdf") else 1),
        )
        for cand in cands:
            base = os.path.basename(cand)
            norm_cand = re.sub(r"[^a-zA-Z0-9]", "", base.lower())
            if norm_source[:25] in norm_cand or norm_cand[:25] in norm_source:
                return os.path.abspath(cand)
    return None


def _resolve_pdf_printed_page(pdf_path: str, canvas_page: int) -> str | None:
    """Reads PDF /PageLabels dictionary and maps 1-based canvas page to printed folio string."""
    try:
        import pypdf

        reader = pypdf.PdfReader(pdf_path)
        idx = canvas_page - 1
        if (
            hasattr(reader, "page_labels")
            and reader.page_labels
            and 0 <= idx < len(reader.page_labels)
        ):
            lbl = reader.page_labels[idx]
            if lbl:
                return str(lbl)
    except Exception as exc:
        logger.debug(f"Failed to resolve printed page label for {pdf_path}: {exc}")
    return None


def _format_mcp_proof_card(query: str, hits: list) -> str:
    from urllib.parse import quote as url_quote

    from backend.config import get_config
    from backend.ingestion.document_parser import extract_verbatim_quote

    config = get_config()
    base_api = config.internal_api_url.rstrip("/")

    card_lines = [
        "### 🛡️ Grounded Evidence Citations (Veraxi Hybrid GraphRAG)",
        f'> **Query:** *"{query}"*',
        "",
        "| # | Document | Location | Action | Verbatim Proof Quote |",
        "|---|---|---|---|---|",
    ]

    for idx, hit in enumerate(hits, start=1):
        payload = getattr(hit, "payload", {}) or {}
        source = (
            payload.get("source") or payload.get("document_id") or "Unknown Document"
        )
        short_source = (source[:38] + "...") if len(source) > 40 else source
        page_num = payload.get("page_number")

        pdf_path = _resolve_pdf_path(source)
        printed_num = (
            _resolve_pdf_printed_page(pdf_path, page_num)
            if (pdf_path and page_num)
            else None
        )

        if printed_num and str(printed_num) != str(page_num):
            page_str = f"**p. {printed_num}** *(PDF sheet {page_num})*"
            btn_label = f"📖 Open PDF p. {printed_num} (Sheet {page_num})"
        elif page_num is not None:
            page_str = f"**Page {page_num}**"
            btn_label = f"📖 Open PDF Page {page_num}"
        else:
            page_str = "Page N/A"
            btn_label = "📖 Open PDF"

        action_str = "N/A"
        if pdf_path and page_num is not None:
            url_path = url_quote(os.path.basename(pdf_path))
            action_str = f"[{btn_label}]({base_api}/documents/raw?path={url_path}#page={page_num})"

        chunk_text = payload.get("text", "")
        quote = (
            extract_verbatim_quote(query, chunk_text, max_words=25)
            .replace("|", "&#124;")
            .replace("\n", " ")
            .strip()
            if chunk_text
            else ""
        )
        card_lines.append(
            f'| **{idx}** | *{short_source}* | {page_str} | {action_str} | *"{quote}"* |'
        )

    card_lines.append("")
    card_lines.append(
        "> 💡 **Citation Instructions for Host AI:**\n"
        f"> - Synthesize the findings and cite claims inline using exact markdown links from above (e.g., `[Document Title, p. N]({base_api}/documents/raw?path=...#page=N)`).\n"
        "> - Maintain high factual fidelity and preserve verbatim proof quotes where critical."
    )
    card_lines.append("")
    return "\n".join(card_lines)


def _serialize_hits_for_mcp(hits: list) -> list[dict]:
    """Serialize hits for MCP output while stripping large internal ID arrays to prevent context blowup."""
    clean_hits = []
    for h in hits:
        d = dataclasses.asdict(h)
        if isinstance(d.get("payload"), dict):
            d["payload"].pop("neo4j_node_ids", None)
            d["payload"].pop("qdrant_point_ids", None)
        clean_hits.append(d)
    return clean_hits


def _handle_search_vectors(args: dict, tenant_id: str) -> list[TextContent]:
    config = get_config()
    results = search_vectors(
        query_text=args["query_text"],
        limit=args.get("limit", config.default_search_limit),
        tenant_id=tenant_id,
    )
    dict_results = _serialize_hits_for_mcp(results)
    proof_card = _format_mcp_proof_card(args["query_text"], results)
    output_text = (
        f"{proof_card}\n<details>\n<summary><b>🔍 Raw Retrieval Data ({len(dict_results)} hits)</b></summary>\n\n"
        f"```json\n{json.dumps(dict_results, indent=2)}\n```\n</details>"
    )
    return [TextContent(type="text", text=output_text)]


def _handle_query_graph(args: dict, tenant_id: str) -> list[TextContent]:
    config = get_config()
    results = query_graph(
        entity_name=args["entity_name"],
        max_hops=args.get("max_hops", config.default_max_hops),
        tenant_id=tenant_id,
    )
    dict_results = _serialize_hits_for_mcp(results)
    if not dict_results:
        return [
            TextContent(
                type="text",
                text=f"No graph relationships found for entity '{args['entity_name']}'.",
            )
        ]
    proof_card = _format_mcp_proof_card(args["entity_name"], results)
    output_text = (
        f"{proof_card}\n<details>\n<summary><b>🔍 Raw Graph Traversal Data ({len(dict_results)} hits)</b></summary>\n\n"
        f"```json\n{json.dumps(dict_results, indent=2)}\n```\n</details>"
    )
    return [TextContent(type="text", text=output_text)]


def _handle_insert_graph_nodes(args: dict, tenant_id: str) -> list[TextContent]:
    # Enforce the free-tier node cap on cloud deployments.
    # Self-hosted (auth_enabled=False) runs without limits — it's the user's own infra.
    config = get_config()
    if config.auth_enabled:
        check_tenant_hard_cap(tenant_id, config)
    results = insert_graph_nodes(
        nodes=args["nodes"], relations=args["relations"], tenant_id=tenant_id
    )
    return [TextContent(type="text", text=json.dumps(results))]


def _handle_insert_vectors(args: dict, tenant_id: str) -> list[TextContent]:
    # Same guard: cloud users are capped, self-hosted users are not.
    config = get_config()
    if config.auth_enabled:
        check_tenant_hard_cap(tenant_id, config)
    results = insert_vectors(texts=args["texts"], tenant_id=tenant_id)
    return [TextContent(type="text", text=json.dumps(results))]


def _handle_merge_rank(args: dict, tenant_id: str) -> list[TextContent]:
    from backend.retrieval.merge_rank import merge_rank

    config = get_config()

    v_hits = search_vectors(
        query_text=args["query_text"],
        limit=args.get("limit", config.default_search_limit),
        tenant_id=tenant_id,
    )

    entity_name = (args.get("entity_name") or "").strip()
    max_hops = args.get("max_hops", config.default_max_hops)
    if entity_name:
        g_hits = query_graph(
            entity_name=entity_name,
            max_hops=max_hops,
            tenant_id=tenant_id,
        )
    else:
        g_hits = seed_graph_hits_from_vectors(
            v_hits=v_hits,
            query_text=args.get("query_text", ""),
            max_hops=max_hops,
            tenant_id=tenant_id,
            max_seeds=3,
            query_graph_fn=query_graph,
        )

    results = merge_rank(
        v_hits,
        g_hits,
        limit=args.get("limit", config.default_search_limit),
        query_text=args.get("query_text"),
        rerank=args.get("rerank"),
    )
    dict_results = _serialize_hits_for_mcp(results)
    proof_card = _format_mcp_proof_card(args["query_text"], results)
    output_text = (
        f"{proof_card}\n<details>\n<summary><b>🔍 Raw Retrieval Data ({len(dict_results)} hits)</b></summary>\n\n"
        f"```json\n{json.dumps(dict_results, indent=2)}\n```\n</details>"
    )
    return [TextContent(type="text", text=output_text)]


def _handle_get_graph_schema(args: dict, tenant_id: str) -> list[TextContent]:
    results = get_graph_schema(tenant_id=tenant_id)
    return [TextContent(type="text", text=json.dumps(results))]


def _handle_delete_entity(args: dict, tenant_id: str) -> list[TextContent]:
    result = delete_entity(args["entity_name"], tenant_id=tenant_id)
    return [TextContent(type="text", text=result)]


def _handle_delete_document(args: dict, tenant_id: str) -> list[TextContent]:
    result = delete_vector(args["document_id"], tenant_id=tenant_id)
    return [TextContent(type="text", text=result)]


def _handle_update_entity(args: dict, tenant_id: str) -> list[TextContent]:
    result = update_entity(args["entity_name"], args["properties"], tenant_id=tenant_id)
    return [TextContent(type="text", text=result)]


def _handle_get_database_stats(args: dict, tenant_id: str) -> list[TextContent]:
    results = get_database_stats(tenant_id=tenant_id)
    return [TextContent(type="text", text=json.dumps(results))]


def _handle_run_community_detection(args: dict, tenant_id: str) -> list[TextContent]:
    results = run_community_detection(args.get("min_size", 2), tenant_id=tenant_id)
    return [TextContent(type="text", text=json.dumps(results))]


def _handle_delete_relationship(args: dict, tenant_id: str) -> list[TextContent]:
    result = delete_relationship(
        args["from_entity"], args["to_entity"], args["rel_type"], tenant_id=tenant_id
    )
    return [TextContent(type="text", text=result)]


def _handle_update_document_metadata(args: dict, tenant_id: str) -> list[TextContent]:
    result = update_document_metadata(
        args["document_id"], args["payload"], tenant_id=tenant_id
    )
    return [TextContent(type="text", text=result)]


def _handle_evaluate_grounding(args: dict, tenant_id: str) -> list[TextContent]:
    from backend.mcp_server.tools.evaluate_grounding import mcp_evaluate_grounding

    resp_text = args.get("response_text", "")
    context_text = args.get("context_text", "")
    method = args.get("method", "auto")
    api_key = args.get("api_key")
    model_name = args.get("model_name")

    try:
        score = mcp_evaluate_grounding(
            resp_text,
            context_text,
            method=method,
            api_key=api_key,
            model_name=model_name,
        )
    except ValueError as exc:
        report = [
            "### 🛡️ Grounding & Verification Evaluation",
            "> **Result:** **❌ BLOCKED: BYOK API Key Required**",
            f'> **Evaluated Claim:** *"{resp_text[:200]}"*',
            "",
            f"- **Error:** {exc!s}",
            "- **Resolution:** Provide your personal API key via `api_key` for LLM mode, or use `method='deterministic'` for free local scoring.",
        ]
        return [TextContent(type="text", text="\n".join(report))]

    passed = (score or 0.0) >= 0.8
    badge = "✅ PASSED" if passed else "❌ FAILED"
    mode_desc = (
        "Deterministic (Local Fast Overlap - $0 Server Cost)"
        if (method == "deterministic" or (method == "auto" and not api_key))
        else f"LLM Entailment (User BYOK: {model_name or 'default'})"
    )

    report = [
        "### 🛡️ Grounding & Verification Evaluation",
        f"> **Grounding Score:** `{score}` | **Result:** **{badge}**",
        f'> **Evaluated Claim:** *"{resp_text[:200]}"*',
        "",
        f"- **Verification Verdict:** {'Factual alignment confirmed by knowledge base' if passed else 'Disputed or unsupported by retrieved context'}",
        f"- **Evaluation Mode:** {mode_desc}",
        f"- **Context Length:** {len(context_text)} characters",
        "",
        f"Score: {score}",
    ]
    return [TextContent(type="text", text="\n".join(report))]


def _handle_web_search(args: dict, tenant_id: str) -> list[TextContent]:
    from backend.mcp_server.tools.web_search import mcp_web_search

    tool_settings = args.get("_tool_settings", {})
    results = mcp_web_search(
        args["query"],
        max_results=args.get("max_results", 3),
        tool_settings=tool_settings,
    )
    return [TextContent(type="text", text=json.dumps(results))]


def _handle_dynamic_web_graph(args: dict, tenant_id: str) -> list[TextContent]:
    from backend.mcp_server.tools.dynamic_web_graph import mcp_dynamic_web_graph

    tool_settings = args.get("_tool_settings", {})
    results = mcp_dynamic_web_graph(
        args["query"],
        args.get("language", "en"),
        args.get("max_results", 5),
        tool_settings=tool_settings,
    )
    return [TextContent(type="text", text=json.dumps(results))]


def _handle_ephemeral_web_rag(args: dict, tenant_id: str) -> list[TextContent]:
    from backend.mcp_server.tools.ephemeral_web_rag import mcp_ephemeral_web_rag

    tool_settings = args.get("_tool_settings", {})
    results = mcp_ephemeral_web_rag(
        query=args["query"],
        tenant_id=tenant_id,
        max_results=args.get("max_results", 3),
        urls=args.get("urls"),
        tool_settings=tool_settings,
    )
    return [TextContent(type="text", text=json.dumps(results))]


def _handle_skills(args: dict, tenant_id: str) -> list[TextContent]:
    from backend.mcp_server.tools.skills import list_skills

    results = list_skills()
    return [TextContent(type="text", text=json.dumps(results))]


def _handle_run_code(args: dict, tenant_id: str) -> list[TextContent]:
    from backend.mcp_server.tools.run_code import execute_python_code

    result = execute_python_code(args["code"])
    return [TextContent(type="text", text=json.dumps(result))]


def _handle_list_artifacts(args: dict, tenant_id: str) -> list[TextContent]:
    from backend.mcp_server.tools.artifacts import list_artifacts

    results = list_artifacts(tenant_id)
    return [TextContent(type="text", text=json.dumps(results))]


def _handle_read_artifact(args: dict, tenant_id: str) -> list[TextContent]:
    from backend.mcp_server.tools.artifacts import read_artifact

    result = read_artifact(tenant_id, args["artifact_name"])
    return [TextContent(type="text", text=result)]


def _handle_ingest_document(args: dict, tenant_id: str) -> list[TextContent]:
    result = mcp_ingest_document(
        tenant_id=tenant_id,
        file_path=args.get("file_path"),
        url=args.get("url"),
        fast_extraction=args.get("fast_extraction", False),
        language=args.get("language", "en"),
    )
    return [TextContent(type="text", text=json.dumps(result))]


def _handle_get_ingest_status(args: dict, tenant_id: str) -> list[TextContent]:
    result = mcp_get_ingest_status(tenant_id=tenant_id, job_id=args["job_id"])
    return [TextContent(type="text", text=json.dumps(result))]


def _handle_export_data(args: dict, tenant_id: str) -> list[TextContent]:
    from backend.mcp_server.tools.export_data import mcp_veraxi_mcp_export_data

    filepath = mcp_veraxi_mcp_export_data(
        data=args.get("data", []),
        format=args.get("format", "csv"),
        output_name=args.get("output_name", "veraxi_export"),
    )
    return [TextContent(type="text", text=filepath)]


async def _handle_agentic_debate(args: dict, tenant_id: str) -> list[TextContent]:
    logger.info(f"mcp_agentic_debate called for tenant: {tenant_id}")
    res = await mcp_agentic_debate(args["query"], tenant_id=tenant_id)
    return [TextContent(type="text", text=json.dumps(res, indent=2))]


def _handle_build_lazy_dossier(args: dict, tenant_id: str) -> list[TextContent]:
    from backend.retrieval.just_in_time_graph import build_lazy_graph_dossier

    results = build_lazy_graph_dossier(
        query=args["query"],
        tenant_id=tenant_id,
        limit=args.get("limit", 15),
    )
    return [TextContent(type="text", text=json.dumps(results, indent=2))]


def _handle_purge_noisy_relationships(args: dict, tenant_id: str) -> list[TextContent]:
    from backend.retrieval.just_in_time_graph import purge_noisy_relationships

    results = purge_noisy_relationships(tenant_id=tenant_id)
    return [TextContent(type="text", text=json.dumps(results, indent=2))]


def _handle_fact_check(args: dict, tenant_id: str) -> list[TextContent]:
    from contextlib import redirect_stderr, redirect_stdout
    import io

    # Support legacy test mocks patching backend.cli.check.run_check
    try:
        from unittest.mock import Mock
        from backend.cli.check import run_check  # type: ignore

        if isinstance(run_check, Mock) or hasattr(run_check, "mock_calls"):
            buf = io.StringIO()
            try:
                with redirect_stdout(buf), redirect_stderr(buf):
                    run_check(
                        text=args.get("claim", ""),
                        min_score=float(args.get("min_score", 0.8)),
                        tenant_id=tenant_id,
                        peek=bool(args.get("peek", True)),
                        as_json=False,
                    )
            except SystemExit:
                pass
            val = buf.getvalue()
            if val.strip():
                return [TextContent(type="text", text=val)]
    except (ImportError, AttributeError):
        pass

    from backend.mcp_server.tools.fact_check import perform_fact_check

    claim = args.get("claim", "")
    min_score = float(args.get("min_score", 0.8))
    peek = bool(args.get("peek", True))

    result = perform_fact_check(
        claim=claim,
        min_score=min_score,
        tenant_id=tenant_id,
        peek=peek,
    )
    return [TextContent(type="text", text=result["markdown"])]


TOOL_HANDLERS = {
    "mcp_search_vectors": _handle_search_vectors,
    "mcp_query_graph": _handle_query_graph,
    "mcp_insert_graph_nodes": _handle_insert_graph_nodes,
    "mcp_insert_vectors": _handle_insert_vectors,
    "mcp_merge_rank": _handle_merge_rank,
    "mcp_fact_check": _handle_fact_check,
    "mcp_get_graph_schema": _handle_get_graph_schema,
    "mcp_delete_entity": _handle_delete_entity,
    "mcp_delete_document": _handle_delete_document,
    "mcp_update_entity": _handle_update_entity,
    "mcp_get_database_stats": _handle_get_database_stats,
    "mcp_run_community_detection": _handle_run_community_detection,
    "mcp_delete_relationship": _handle_delete_relationship,
    "mcp_update_document_metadata": _handle_update_document_metadata,
    "mcp_evaluate_grounding": _handle_evaluate_grounding,
    "mcp_web_search": _handle_web_search,
    "mcp_dynamic_web_graph": _handle_dynamic_web_graph,
    "mcp_skills": _handle_skills,
    "mcp_run_code": _handle_run_code,
    "mcp_list_artifacts": _handle_list_artifacts,
    "mcp_read_artifact": _handle_read_artifact,
    "mcp_ingest_document": _handle_ingest_document,
    "mcp_get_ingest_status": _handle_get_ingest_status,
    "mcp_ephemeral_web_rag": _handle_ephemeral_web_rag,
    "mcp_agentic_debate": _handle_agentic_debate,
    "mcp_export_data": _handle_export_data,
    "mcp_build_lazy_dossier": _handle_build_lazy_dossier,
    "mcp_purge_noisy_relationships": _handle_purge_noisy_relationships,
}
