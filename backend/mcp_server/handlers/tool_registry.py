import dataclasses
import json
import logging

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
from backend.mcp_server.tools.query_graph import query_graph
from backend.mcp_server.tools.run_analytics import run_community_detection
from backend.mcp_server.tools.search_vectors import search_vectors
from backend.mcp_server.tools.update_document import update_document_metadata
from backend.mcp_server.tools.update_entity import update_entity
from backend.storage.graph_operations import insert_graph_nodes
from backend.storage.quota import check_tenant_hard_cap

__all__ = ["REGISTERED_TOOLS", "TOOL_HANDLERS"]

logger = logging.getLogger(__name__)


def _handle_search_vectors(args: dict, tenant_id: str) -> list[TextContent]:
    config = get_config()
    results = search_vectors(
        query_text=args["query_text"],
        limit=args.get("limit", config.default_search_limit),
        tenant_id=tenant_id,
    )
    dict_results = [dataclasses.asdict(r) for r in results]
    return [TextContent(type="text", text=json.dumps(dict_results))]


def _handle_query_graph(args: dict, tenant_id: str) -> list[TextContent]:
    config = get_config()
    results = query_graph(
        entity_name=args["entity_name"],
        max_hops=args.get("max_hops", config.default_max_hops),
        tenant_id=tenant_id,
    )
    return [TextContent(type="text", text=json.dumps(results))]


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
    import dataclasses

    from backend.retrieval.merge_rank import merge_rank

    config = get_config()

    v_hits = search_vectors(
        query_text=args["query_text"],
        limit=args.get("limit", config.default_search_limit),
        tenant_id=tenant_id,
    )

    entity_name = (args.get("entity_name") or "").strip()
    g_hits = []
    if entity_name:
        g_hits = query_graph(
            entity_name=entity_name,
            max_hops=args.get("max_hops", config.default_max_hops),
            tenant_id=tenant_id,
        )
    else:
        # Seed graph traversal from entity candidates found in vector chunk payloads
        for v in v_hits[:3]:
            payload = getattr(v, "payload", {}) or {}
            candidate = payload.get("entity_name") or payload.get("title")
            if candidate and isinstance(candidate, str):
                g_hits = query_graph(
                    entity_name=candidate,
                    max_hops=args.get("max_hops", config.default_max_hops),
                    tenant_id=tenant_id,
                )
                if g_hits:
                    break

    results = merge_rank(
        v_hits, g_hits, limit=args.get("limit", config.default_search_limit)
    )
    dict_results = [dataclasses.asdict(r) for r in results]

    return [TextContent(type="text", text=json.dumps(dict_results))]


def _handle_get_graph_schema(args: dict, tenant_id: str) -> list[TextContent]:
    results = get_graph_schema()
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
    results = run_community_detection(args.get("min_size", 2))
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

    score = mcp_evaluate_grounding(args["response_text"], args["context_text"])
    return [TextContent(type="text", text=str(score))]


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


TOOL_HANDLERS = {
    "mcp_search_vectors": _handle_search_vectors,
    "mcp_query_graph": _handle_query_graph,
    "mcp_insert_graph_nodes": _handle_insert_graph_nodes,
    "mcp_insert_vectors": _handle_insert_vectors,
    "mcp_merge_rank": _handle_merge_rank,
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
