"""SOC / SIEM Security Alert & IOC Correlation ingestion for Hybrid GraphRAG.

Parses structured security alerts (JSON / ECS-like dicts) into
``SecurityAlert`` and ``IOC`` nodes in Neo4j, linking them to ``TargetHost``,
``AttackTechnique`` (MITRE ATT&CK), and ``CVE`` nodes, and optionally
indexing alerts in Qdrant.
"""

from __future__ import annotations

import logging
import re
import uuid
from typing import Any

logger = logging.getLogger(__name__)

_TECHNIQUE_RE = re.compile(r"\b(T\d{4}(?:\.\d{3})?)\b", re.IGNORECASE)
_CVE_RE = re.compile(r"\b(CVE-\d{4}-\d{4,})\b", re.IGNORECASE)


def _as_str_list(val: Any) -> list[str]:
    if isinstance(val, str):
        return [val.strip()] if val.strip() else []
    if isinstance(val, list):
        return [str(v).strip() for v in val if str(v).strip()]
    return []


def parse_alert_payload(payload: dict[str, Any] | list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Normalize a single alert dict or list of alert dicts."""
    raw_items = payload if isinstance(payload, list) else [payload]
    alerts: list[dict[str, Any]] = []
    for item in raw_items:
        if not isinstance(item, dict):
            continue
        title = str(item.get("title") or item.get("rule_name") or item.get("name") or "Security Alert")
        description = str(item.get("description") or item.get("message") or "")
        combined = f"{title} {description}"
        techs = [t.upper() for t in _as_str_list(item.get("technique_ids"))]
        for m in _TECHNIQUE_RE.findall(combined):
            if m.upper() not in techs:
                techs.append(m.upper())
        cves = [c.upper() for c in _as_str_list(item.get("cve_ids"))]
        for m in _CVE_RE.findall(combined):
            if m.upper() not in cves:
                cves.append(m.upper())

        iocs: list[dict[str, str]] = []
        for field_name, kind in (
            ("source_ip", "ip"),
            ("dest_ip", "ip"),
            ("ip", "ip"),
            ("file_hash", "hash"),
            ("sha256", "hash"),
            ("domain", "domain"),
        ):
            for val in _as_str_list(item.get(field_name)):
                iocs.append({"value": val, "kind": kind})
        for raw_ioc in _as_str_list(item.get("iocs")):
            iocs.append({"value": raw_ioc, "kind": "indicator"})

        alert_id = str(
            item.get("alert_id")
            or item.get("id")
            or uuid.uuid5(uuid.NAMESPACE_URL, f"{title}:{item.get('host', '')}:{item.get('timestamp', '')}")
        )
        alerts.append(
            {
                "alert_id": alert_id,
                "title": title,
                "severity": str(item.get("severity") or "MEDIUM").upper(),
                "description": description,
                "host": str(item.get("host") or "").strip(),
                "timestamp": str(item.get("timestamp") or "").strip(),
                "technique_ids": techs,
                "cve_ids": cves,
                "iocs": iocs,
            }
        )
    return alerts


def _alert_key(tenant_id: str, alert_id: str) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"veraxi:alert:{tenant_id}:{alert_id}"))


def index_alert_vectors(
    qdrant_client: Any,
    alerts: list[dict[str, Any]],
    tenant_id: str = "default",
    collection_name: str | None = None,
) -> int:
    """Embed and upsert security alerts into Qdrant, setting ``qdrant_point_ids``."""
    if not alerts:
        return 0
    from backend.config import get_config
    from backend.ingestion.chunk_embed import embed_text, embed_text_sparse

    col = collection_name or get_config().qdrant_collection_name
    vectors: list[list[float]] = []
    sparse_vectors: list[dict[str, Any]] = []
    payloads: list[dict[str, Any]] = []
    for a in alerts:
        pid = _alert_key(tenant_id, a["alert_id"])
        a["qdrant_point_ids"] = [pid]
        ioc_vals = ", ".join(i["value"] for i in a.get("iocs") or [])
        text = (
            f"[SOC {a['severity']}] {a['title']} host={a.get('host', '')} "
            f"techniques={','.join(a.get('technique_ids') or [])} "
            f"iocs={ioc_vals} — {a.get('description', '')}"
        )
        vectors.append(embed_text(text))
        sparse_vectors.append(embed_text_sparse(text))
        payloads.append(
            {
                "point_id": pid,
                "text": text,
                "title": f"[{a['severity']}] {a['title']}",
                "alert_id": a["alert_id"],
                "severity": a["severity"],
                "host": a.get("host", ""),
                "technique_ids": list(a.get("technique_ids") or []),
                "cve_ids": list(a.get("cve_ids") or []),
                "source_type": "soc_alert",
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


def write_security_alerts(
    neo4j_client: Any,
    alerts: list[dict[str, Any]],
    tenant_id: str = "default",
    qdrant_client: Any = None,
) -> dict[str, int]:
    """Persist security alerts, IOCs, and ATT&CK/CVE/Host links to Neo4j."""
    if not alerts:
        return {
            "alerts_written": 0,
            "ioc_links": 0,
            "technique_links": 0,
            "cve_links": 0,
            "vectors_written": 0,
        }

    vectors_written = 0
    if qdrant_client is not None:
        vectors_written = index_alert_vectors(qdrant_client, alerts, tenant_id=tenant_id)

    alert_rows = []
    host_nodes: dict[str, dict[str, Any]] = {}
    host_edges = []
    ioc_nodes: dict[str, dict[str, Any]] = {}
    ioc_edges = []
    tech_edges = []
    cve_edges = []

    for a in alerts:
        akey = _alert_key(tenant_id, a["alert_id"])
        props: dict[str, Any] = {
            "id": a["alert_id"],
            "name": a["title"],
            "severity": a["severity"],
            "description": a.get("description", ""),
            "host": a.get("host", ""),
            "timestamp": a.get("timestamp", ""),
            "tenant_id": tenant_id,
        }
        if a.get("qdrant_point_ids"):
            props["qdrant_point_ids"] = list(a["qdrant_point_ids"])
        alert_rows.append({"alert_key": akey, "properties": props})

        if a.get("host"):
            hkey = f"{tenant_id}::TargetHost::{a['host']}"
            host_nodes.setdefault(
                hkey,
                {
                    "recon_key": hkey,
                    "properties": {"id": a["host"], "name": a["host"], "tenant_id": tenant_id},
                },
            )
            host_edges.append({"host_key": hkey, "alert_key": akey, "tenant_id": tenant_id})

        for ioc in a.get("iocs") or []:
            ikey = f"{tenant_id}::IOC::{ioc['value']}"
            ioc_nodes.setdefault(
                ikey,
                {
                    "ioc_key": ikey,
                    "properties": {
                        "id": ioc["value"],
                        "name": ioc["value"],
                        "kind": ioc["kind"],
                        "tenant_id": tenant_id,
                    },
                },
            )
            ioc_edges.append({"alert_key": akey, "ioc_key": ikey, "tenant_id": tenant_id})

        for tid in a.get("technique_ids") or []:
            tech_edges.append(
                {"alert_key": akey, "technique_id": tid, "tenant_id": tenant_id}
            )
        for cid in a.get("cve_ids") or []:
            cve_edges.append({"alert_key": akey, "cve_id": cid, "tenant_id": tenant_id})

    neo4j_client.execute_write(
        """
        UNWIND $rows AS row
        MERGE (n:SecurityAlert {alert_key: row.alert_key})
        SET n += row.properties
        """,
        {"rows": alert_rows},
    )
    if host_nodes:
        neo4j_client.execute_write(
            """
            UNWIND $rows AS row
            MERGE (h:TargetHost {recon_key: row.recon_key})
            SET h += row.properties
            """,
            {"rows": list(host_nodes.values())},
        )
        neo4j_client.execute_write(
            """
            UNWIND $rows AS row
            MATCH (h:TargetHost {recon_key: row.host_key})
            MATCH (a:SecurityAlert {alert_key: row.alert_key})
            MERGE (h)-[r:TRIGGERED_ALERT]->(a)
            SET r.tenant_id = row.tenant_id
            """,
            {"rows": host_edges},
        )
    if ioc_nodes:
        neo4j_client.execute_write(
            """
            UNWIND $rows AS row
            MERGE (i:IOC {ioc_key: row.ioc_key})
            SET i += row.properties
            """,
            {"rows": list(ioc_nodes.values())},
        )
        neo4j_client.execute_write(
            """
            UNWIND $rows AS row
            MATCH (a:SecurityAlert {alert_key: row.alert_key})
            MATCH (i:IOC {ioc_key: row.ioc_key})
            MERGE (a)-[r:OBSERVED_IOC]->(i)
            SET r.tenant_id = row.tenant_id
            """,
            {"rows": ioc_edges},
        )
    if tech_edges:
        neo4j_client.execute_write(
            """
            UNWIND $rows AS row
            MATCH (a:SecurityAlert {alert_key: row.alert_key})
            MATCH (t:AttackTechnique {id: row.technique_id})
            WHERE t.tenant_id IN [row.tenant_id, 'public']
            MERGE (a)-[r:USES_TECHNIQUE]->(t)
            SET r.tenant_id = row.tenant_id
            """,
            {"rows": tech_edges},
        )
    if cve_edges:
        neo4j_client.execute_write(
            """
            UNWIND $rows AS row
            MATCH (a:SecurityAlert {alert_key: row.alert_key})
            MATCH (c:CVE {id: row.cve_id})
            WHERE c.tenant_id IN [row.tenant_id, 'public']
            MERGE (a)-[r:EXPLOITS_CVE]->(c)
            SET r.tenant_id = row.tenant_id
            """,
            {"rows": cve_edges},
        )

    return {
        "alerts_written": len(alert_rows),
        "ioc_links": len(ioc_edges),
        "technique_links": len(tech_edges),
        "cve_links": len(cve_edges),
        "vectors_written": vectors_written,
    }


__all__ = ["index_alert_vectors", "parse_alert_payload", "write_security_alerts"]
