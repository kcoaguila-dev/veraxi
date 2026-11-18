"""MITRE ATT&CK (STIX 2.1) ingestion for threat-modeling & white-hat Hybrid RAG.

Parses official MITRE ATT&CK STIX 2.1 bundles (Enterprise ATT&CK) into
``AttackTechnique``, ``AttackTactic``, and ``AttackMitigation`` nodes plus
``IN_TACTIC``, ``MITIGATES``, and ``MAPS_TO_CWE`` edges in Neo4j, and
optionally indexes technique/mitigation descriptions in Qdrant.
"""

from __future__ import annotations

import logging
import re
import uuid
from typing import Any

import httpx

logger = logging.getLogger(__name__)

ENTERPRISE_ATTACK_URL = (
    "https://raw.githubusercontent.com/mitre/cti/master/"
    "enterprise-attack/enterprise-attack.json"
)
_CWE_RE = re.compile(r"\b(CWE-\d+)\b", re.IGNORECASE)


def _attack_external_id(obj: dict[str, Any]) -> str:
    for ref in obj.get("external_references") or []:
        if isinstance(ref, dict) and ref.get("source_name") == "mitre-attack":
            ext_id = str(ref.get("external_id") or "").strip()
            if ext_id:
                return ext_id
    return str(obj.get("id") or "")


def _extract_cwe_refs(obj: dict[str, Any]) -> list[str]:
    cwes: list[str] = []
    for ref in obj.get("external_references") or []:
        if not isinstance(ref, dict):
            continue
        text = f"{ref.get('source_name', '')} {ref.get('external_id', '')} {ref.get('description', '')}"
        for match in _CWE_RE.findall(text):
            norm = match.upper()
            if norm not in cwes:
                cwes.append(norm)
    return cwes


def parse_attack_stix_payload(payload: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    """Parse a STIX 2.1 bundle into techniques, tactics, mitigations, and edges."""
    techniques: list[dict[str, Any]] = []
    tactics: dict[str, dict[str, Any]] = {}
    mitigations: dict[str, dict[str, Any]] = {}
    mitigates_edges: list[dict[str, str]] = []
    tech_by_stix: dict[str, str] = {}
    mit_by_stix: dict[str, str] = {}

    objects = (payload or {}).get("objects") or []
    for obj in objects:
        if not isinstance(obj, dict) or obj.get("revoked") or obj.get("x_mitre_deprecated"):
            continue
        otype = obj.get("type")
        stix_id = str(obj.get("id") or "")
        if otype == "x-mitre-tactic":
            short = str(obj.get("x_mitre_shortname") or obj.get("name") or "").strip()
            if short:
                tactics[short] = {
                    "id": _attack_external_id(obj) or short,
                    "name": str(obj.get("name") or short),
                    "shortname": short,
                    "description": str(obj.get("description") or ""),
                }
        elif otype == "attack-pattern":
            ext_id = _attack_external_id(obj)
            if not ext_id:
                continue
            phases = [
                str(p.get("phase_name") or "").strip()
                for p in (obj.get("kill_chain_phases") or [])
                if isinstance(p, dict) and p.get("kill_chain_name") == "mitre-attack"
            ]
            tech = {
                "id": ext_id,
                "name": str(obj.get("name") or ext_id),
                "description": str(obj.get("description") or ""),
                "platforms": list(obj.get("x_mitre_platforms") or []),
                "tactics": [p for p in phases if p],
                "cwe_ids": _extract_cwe_refs(obj),
            }
            techniques.append(tech)
            if stix_id:
                tech_by_stix[stix_id] = ext_id
        elif otype == "course-of-action":
            ext_id = _attack_external_id(obj)
            if not ext_id:
                continue
            mitigations[ext_id] = {
                "id": ext_id,
                "name": str(obj.get("name") or ext_id),
                "description": str(obj.get("description") or ""),
            }
            if stix_id:
                mit_by_stix[stix_id] = ext_id

    for obj in objects:
        if not isinstance(obj, dict) or obj.get("type") != "relationship":
            continue
        if obj.get("relationship_type") != "mitigates":
            continue
        src = mit_by_stix.get(str(obj.get("source_ref") or ""))
        dst = tech_by_stix.get(str(obj.get("target_ref") or ""))
        if src and dst:
            mitigates_edges.append({"mitigation_id": src, "technique_id": dst})

    return {
        "techniques": techniques,
        "tactics": list(tactics.values()),
        "mitigations": list(mitigations.values()),
        "mitigates": mitigates_edges,
    }


def _attack_key(tenant_id: str, label: str, identifier: str) -> str:
    return f"{tenant_id}::{label}::{identifier}"


def index_attack_vectors(
    qdrant_client: Any,
    techniques: list[dict[str, Any]],
    tenant_id: str = "default",
    collection_name: str | None = None,
) -> int:
    """Embed and upsert ATT&CK techniques into Qdrant, setting ``qdrant_point_ids``."""
    if not techniques:
        return 0
    from backend.config import get_config
    from backend.ingestion.chunk_embed import embed_text, embed_text_sparse

    col = collection_name or get_config().qdrant_collection_name
    vectors: list[list[float]] = []
    sparse_vectors: list[dict[str, Any]] = []
    payloads: list[dict[str, Any]] = []
    for tech in techniques:
        pid = str(
            uuid.uuid5(uuid.NAMESPACE_URL, f"veraxi:attack:{tenant_id}:{tech['id']}")
        )
        tech["qdrant_point_ids"] = [pid]
        tactics = ", ".join(tech.get("tactics") or [])
        text = f"{tech['id']} {tech['name']} [{tactics}] — {tech.get('description', '')}"
        vectors.append(embed_text(text))
        sparse_vectors.append(embed_text_sparse(text))
        payloads.append(
            {
                "point_id": pid,
                "text": text,
                "title": f"{tech['id']}: {tech['name']}",
                "technique_id": tech["id"],
                "tactics": list(tech.get("tactics") or []),
                "source_type": "mitre_attack",
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


def write_attack_intel(
    neo4j_client: Any,
    parsed: dict[str, list[dict[str, Any]]],
    tenant_id: str = "default",
    qdrant_client: Any = None,
) -> dict[str, int]:
    """Persist parsed ATT&CK nodes and edges to Neo4j (and optionally Qdrant)."""
    techniques = parsed.get("techniques") or []
    tactics = parsed.get("tactics") or []
    mitigations = parsed.get("mitigations") or []
    mitigates = parsed.get("mitigates") or []

    vectors_written = 0
    if qdrant_client is not None and techniques:
        vectors_written = index_attack_vectors(
            qdrant_client, techniques, tenant_id=tenant_id
        )

    if tactics:
        tactic_rows = [
            {
                "attack_key": _attack_key(tenant_id, "AttackTactic", t["shortname"]),
                "properties": {**t, "tenant_id": tenant_id},
            }
            for t in tactics
        ]
        neo4j_client.execute_write(
            """
            UNWIND $rows AS row
            MERGE (n:AttackTactic {attack_key: row.attack_key})
            SET n += row.properties
            """,
            {"rows": tactic_rows},
        )

    if mitigations:
        mit_rows = [
            {
                "attack_key": _attack_key(tenant_id, "AttackMitigation", m["id"]),
                "properties": {**m, "tenant_id": tenant_id},
            }
            for m in mitigations
        ]
        neo4j_client.execute_write(
            """
            UNWIND $rows AS row
            MERGE (n:AttackMitigation {attack_key: row.attack_key})
            SET n += row.properties
            """,
            {"rows": mit_rows},
        )

    tactic_edges: list[dict[str, str]] = []
    cwe_edges: list[dict[str, str]] = []
    if techniques:
        tech_rows = []
        for tech in techniques:
            tkey = _attack_key(tenant_id, "AttackTechnique", tech["id"])
            props: dict[str, Any] = {
                "id": tech["id"],
                "name": tech["name"],
                "description": tech.get("description", ""),
                "platforms": list(tech.get("platforms") or []),
                "aliases": [tech["id"]],
                "tenant_id": tenant_id,
            }
            if tech.get("qdrant_point_ids"):
                props["qdrant_point_ids"] = list(tech["qdrant_point_ids"])
            tech_rows.append({"attack_key": tkey, "properties": props})
            for short in tech.get("tactics") or []:
                tactic_edges.append(
                    {
                        "tech_key": tkey,
                        "tactic_key": _attack_key(tenant_id, "AttackTactic", short),
                        "tenant_id": tenant_id,
                    }
                )
            for cwe_id in tech.get("cwe_ids") or []:
                cwe_edges.append(
                    {
                        "tech_key": tkey,
                        "cwe_key": f"{tenant_id}::CWE::{cwe_id}",
                        "cwe_id": cwe_id,
                        "tenant_id": tenant_id,
                    }
                )
        neo4j_client.execute_write(
            """
            UNWIND $rows AS row
            MERGE (n:AttackTechnique {attack_key: row.attack_key})
            SET n += row.properties
            """,
            {"rows": tech_rows},
        )

    if tactic_edges:
        neo4j_client.execute_write(
            """
            UNWIND $rows AS row
            MATCH (t:AttackTechnique {attack_key: row.tech_key})
            MATCH (tac:AttackTactic {attack_key: row.tactic_key})
            MERGE (t)-[r:IN_TACTIC]->(tac)
            SET r.tenant_id = row.tenant_id
            """,
            {"rows": tactic_edges},
        )

    if cwe_edges:
        neo4j_client.execute_write(
            """
            UNWIND $rows AS row
            MERGE (c:CWE {vuln_key: row.cwe_key})
            ON CREATE SET c.id = row.cwe_id, c.tenant_id = row.tenant_id
            WITH row, c
            MATCH (t:AttackTechnique {attack_key: row.tech_key})
            MERGE (t)-[r:MAPS_TO_CWE]->(c)
            SET r.tenant_id = row.tenant_id
            """,
            {"rows": cwe_edges},
        )

    if mitigates:
        mit_edges = [
            {
                "mit_key": _attack_key(tenant_id, "AttackMitigation", e["mitigation_id"]),
                "tech_key": _attack_key(tenant_id, "AttackTechnique", e["technique_id"]),
                "tenant_id": tenant_id,
            }
            for e in mitigates
        ]
        neo4j_client.execute_write(
            """
            UNWIND $rows AS row
            MATCH (m:AttackMitigation {attack_key: row.mit_key})
            MATCH (t:AttackTechnique {attack_key: row.tech_key})
            MERGE (m)-[r:MITIGATES]->(t)
            SET r.tenant_id = row.tenant_id
            """,
            {"rows": mit_edges},
        )

    return {
        "techniques_written": len(techniques),
        "tactics_written": len(tactics),
        "mitigations_written": len(mitigations),
        "mitigates_links": len(mitigates),
        "vectors_written": vectors_written,
    }


def fetch_attack_stix(client: httpx.Client | None = None) -> dict[str, Any]:
    """Download the official MITRE Enterprise ATT&CK STIX 2.1 JSON bundle."""
    own_client = client is None
    http_client = client or httpx.Client(timeout=60.0)
    try:
        resp = http_client.get(ENTERPRISE_ATTACK_URL)
        resp.raise_for_status()
        return resp.json() or {}
    finally:
        if own_client:
            http_client.close()


__all__ = [
    "ENTERPRISE_ATTACK_URL",
    "fetch_attack_stix",
    "index_attack_vectors",
    "parse_attack_stix_payload",
    "write_attack_intel",
]
