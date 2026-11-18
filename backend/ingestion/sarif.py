"""SARIF 2.1.0 ingestion for SAST/scanner findings (Semgrep, Opengrep, Trivy, CodeQL).

Parses SARIF JSON into normalized finding dicts and persists them to Neo4j
(:SecurityFinding linked to :CodeFile and :CWE) and optionally Qdrant.
All Cypher queries are parameterized and tenant-scoped.
"""

from __future__ import annotations

import logging
import re
import uuid
from typing import Any

logger = logging.getLogger(__name__)

_CWE_RE = re.compile(r"\b(CWE-\d+)\b", re.IGNORECASE)
_LEVEL_TO_SEVERITY = {
    "error": "HIGH",
    "warning": "MEDIUM",
    "note": "LOW",
    "none": "INFO",
}


def _extract_rule_cwes(rule: dict[str, Any]) -> list[str]:
    cwes: list[str] = []
    props = rule.get("properties") or {}
    for tag in props.get("tags") or []:
        for match in _CWE_RE.findall(str(tag)):
            normalized = match.upper()
            if normalized not in cwes:
                cwes.append(normalized)
    for rel in rule.get("relationships") or []:
        target_id = ((rel or {}).get("target") or {}).get("id") or ""
        for match in _CWE_RE.findall(str(target_id)):
            normalized = match.upper()
            if normalized not in cwes:
                cwes.append(normalized)
    return cwes


def _extract_taint_path(result: dict[str, Any]) -> list[str]:
    """Extract source-to-sink step locations from SARIF ``codeFlows``."""
    steps: list[str] = []
    for code_flow in result.get("codeFlows") or []:
        if not isinstance(code_flow, dict):
            continue
        for thread_flow in code_flow.get("threadFlows") or []:
            if not isinstance(thread_flow, dict):
                continue
            for loc_entry in thread_flow.get("locations") or []:
                loc = (loc_entry or {}).get("location") or {}
                phys = loc.get("physicalLocation") or {}
                uri = ((phys.get("artifactLocation") or {}).get("uri")) or ""
                line = ((phys.get("region") or {}).get("startLine")) or 0
                if uri:
                    steps.append(f"{uri}:{line}" if line else uri)
            if steps:
                return steps
    return steps


def parse_sarif_payload(payload: dict[str, Any]) -> list[dict[str, Any]]:
    """Parse a SARIF 2.1.0 JSON dict into normalized finding records."""
    findings: list[dict[str, Any]] = []
    for run in (payload or {}).get("runs") or []:
        if not isinstance(run, dict):
            continue
        driver = (run.get("tool") or {}).get("driver") or {}
        tool_name = str(driver.get("name") or "sarif")
        rules_by_id = {
            r.get("id"): r
            for r in (driver.get("rules") or [])
            if isinstance(r, dict) and r.get("id")
        }
        for result in run.get("results") or []:
            if not isinstance(result, dict):
                continue
            rule_id = str(result.get("ruleId") or "unknown")
            rule = rules_by_id.get(rule_id) or {}
            level = str(result.get("level") or "warning").lower()
            message = str(((result.get("message") or {}).get("text")) or "")
            locations = result.get("locations") or []
            phys = (locations[0].get("physicalLocation") or {}) if locations else {}
            path = str(((phys.get("artifactLocation") or {}).get("uri")) or "")
            line = int(((phys.get("region") or {}).get("startLine")) or 0)
            cwes = _extract_rule_cwes(rule)
            for match in _CWE_RE.findall(message):
                norm = match.upper()
                if norm not in cwes:
                    cwes.append(norm)
            findings.append(
                {
                    "tool": tool_name,
                    "rule_id": rule_id,
                    "severity": _LEVEL_TO_SEVERITY.get(level, "MEDIUM"),
                    "message": message,
                    "path": path,
                    "line": line,
                    "cwe_ids": cwes,
                    "taint_path": _extract_taint_path(result),
                }
            )
    return findings


def _finding_key(tenant_id: str, finding: dict[str, Any]) -> str:
    raw = f"{tenant_id}:{finding['tool']}:{finding['rule_id']}:{finding['path']}:{finding['line']}"
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"veraxi:sarif:{raw}"))


def index_sarif_vectors(
    qdrant_client: Any,
    findings: list[dict[str, Any]],
    tenant_id: str = "default",
    collection_name: str | None = None,
) -> int:
    """Embed and upsert SARIF findings into Qdrant, setting ``qdrant_point_ids``."""
    if not findings:
        return 0
    from backend.config import get_config
    from backend.ingestion.chunk_embed import embed_text, embed_text_sparse

    col = collection_name or get_config().qdrant_collection_name
    vectors: list[list[float]] = []
    sparse_vectors: list[dict[str, Any]] = []
    payloads: list[dict[str, Any]] = []
    for f in findings:
        pid = _finding_key(tenant_id, f)
        f["qdrant_point_ids"] = [pid]
        taint_path = f.get("taint_path") or []
        taint_suffix = f" [taint: {' -> '.join(taint_path)}]" if taint_path else ""
        text = (
            f"[{f['tool']} {f['severity']}] {f['rule_id']} at "
            f"{f['path']}:{f['line']} — {f['message']}{taint_suffix}"
        )
        vectors.append(embed_text(text))
        sparse_vectors.append(embed_text_sparse(text))
        payloads.append(
            {
                "point_id": pid,
                "text": text,
                "title": f"{f['rule_id']} ({f['path']}:{f['line']})",
                "tool": f["tool"],
                "rule_id": f["rule_id"],
                "severity": f["severity"],
                "path": f["path"],
                "line": f["line"],
                "cwe_ids": list(f.get("cwe_ids") or []),
                "source_type": "sast_sarif",
                "tenant_id": tenant_id,
            }
        )
    qdrant_client.insert_points(
        col,
        vectors,
        sparse_vectors=sparse_vectors,
        payloads=payloads,
        tenant_id=tenant_id,
    )
    return len(payloads)


def write_sarif_findings(
    neo4j_client: Any,
    findings: list[dict[str, Any]],
    tenant_id: str = "default",
    qdrant_client: Any = None,
) -> dict[str, int]:
    """Persist SARIF findings to Neo4j (and optionally Qdrant) via parameterized Cypher."""
    if not findings:
        return {"findings_written": 0, "file_links": 0, "cwe_links": 0, "vectors_written": 0}

    vectors_written = 0
    if qdrant_client is not None:
        vectors_written = index_sarif_vectors(qdrant_client, findings, tenant_id=tenant_id)

    rows = []
    file_edges = []
    cwe_edges = []
    for f in findings:
        fkey = _finding_key(tenant_id, f)
        props: dict[str, Any] = {
            "id": fkey,
            "name": f"{f['rule_id']}@{f['path']}:{f['line']}",
            "tool": f["tool"],
            "rule_id": f["rule_id"],
            "severity": f["severity"],
            "description": f["message"],
            "path": f["path"],
            "line": f["line"],
            "taint_path": list(f.get("taint_path") or []),
            "tenant_id": tenant_id,
        }
        if f.get("qdrant_point_ids"):
            props["qdrant_point_ids"] = list(f["qdrant_point_ids"])
        rows.append({"finding_key": fkey, "properties": props})
        if f["path"]:
            file_edges.append({"finding_key": fkey, "path": f["path"], "tenant_id": tenant_id})
        for cwe_id in f.get("cwe_ids") or []:
            cwe_key = f"{tenant_id}::CWE::{cwe_id}"
            cwe_edges.append(
                {
                    "finding_key": fkey,
                    "cwe_key": cwe_key,
                    "cwe_id": cwe_id,
                    "tenant_id": tenant_id,
                }
            )

    neo4j_client.execute_write(
        """
        UNWIND $rows AS row
        MERGE (n:SecurityFinding {finding_key: row.finding_key})
        SET n += row.properties
        """,
        {"rows": rows},
    )
    if file_edges:
        neo4j_client.execute_write(
            """
            UNWIND $rows AS row
            MATCH (f:CodeFile {tenant_id: row.tenant_id, path: row.path})
            MATCH (s:SecurityFinding {finding_key: row.finding_key})
            MERGE (f)-[r:HAS_FINDING]->(s)
            SET r.tenant_id = row.tenant_id
            """,
            {"rows": file_edges},
        )
    if cwe_edges:
        neo4j_client.execute_write(
            """
            UNWIND $rows AS row
            MERGE (c:CWE {vuln_key: row.cwe_key})
            ON CREATE SET c.id = row.cwe_id, c.tenant_id = row.tenant_id
            WITH row, c
            MATCH (s:SecurityFinding {finding_key: row.finding_key})
            MERGE (s)-[r:HAS_WEAKNESS]->(c)
            SET r.tenant_id = row.tenant_id
            """,
            {"rows": cwe_edges},
        )
    return {
        "findings_written": len(rows),
        "file_links": len(file_edges),
        "cwe_links": len(cwe_edges),
        "vectors_written": vectors_written,
    }


__all__ = ["index_sarif_vectors", "parse_sarif_payload", "write_sarif_findings"]
