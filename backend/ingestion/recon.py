"""Recon / DAST ingestion (Nuclei, Nmap XML, Burp XML, Caido JSON) for Hybrid RAG.

Parses ProjectDiscovery Nuclei JSON/JSONL, Nmap XML, Burp Suite XML, and
Caido findings JSON into ``TargetHost`` and ``ReconFinding`` nodes linked
to ``CVE`` and ``CWE`` nodes in Neo4j, and optionally indexes findings in Qdrant.
"""

from __future__ import annotations

import json
import logging
import re
import uuid
import xml.etree.ElementTree as ET
from typing import Any
from urllib.parse import urlparse

logger = logging.getLogger(__name__)

_CVE_RE = re.compile(r"\b(CVE-\d{4}-\d{4,})\b", re.IGNORECASE)
_CWE_RE = re.compile(r"\b(CWE-\d+)\b", re.IGNORECASE)
_UNSAFE_XML_RE = re.compile(r"<!(?:DOCTYPE|ENTITY)\b", re.IGNORECASE)


def _safe_xml_root(xml_text: str) -> ET.Element | None:
    """Parse XML rejecting DOCTYPE/ENTITY declarations to prevent XXE."""
    if not xml_text or _UNSAFE_XML_RE.search(xml_text):
        return None
    try:
        return ET.fromstring(xml_text)
    except ET.ParseError:
        return None


def parse_nmap_xml(xml_text: str) -> list[dict[str, Any]]:
    """Parse Nmap XML (open ports, services, and NSE vuln script CVEs)."""
    root = _safe_xml_root(xml_text)
    if root is None or root.tag != "nmaprun":
        return []
    findings: list[dict[str, Any]] = []
    for host_el in root.findall("host"):
        addr_el = host_el.find("address")
        host = (addr_el.get("addr") if addr_el is not None else "") or ""
        hn_el = host_el.find("hostnames/hostname")
        if hn_el is not None and hn_el.get("name"):
            host = hn_el.get("name") or host
        for port_el in host_el.findall("ports/port"):
            state_el = port_el.find("state")
            if state_el is None or state_el.get("state") != "open":
                continue
            port_id = port_el.get("portid") or ""
            proto = port_el.get("protocol") or "tcp"
            svc_el = port_el.find("service")
            svc_name = (svc_el.get("name") if svc_el is not None else "") or "service"
            product = (svc_el.get("product") if svc_el is not None else "") or ""
            version = (svc_el.get("version") if svc_el is not None else "") or ""
            script_text = " ".join(
                (s.get("output") or "") for s in port_el.findall("script")
            )
            cves = sorted({m.upper() for m in _CVE_RE.findall(script_text)})
            findings.append(
                {
                    "template_id": f"nmap:{proto}/{port_id}/{svc_name}",
                    "name": f"Open {svc_name} ({proto}/{port_id}) {product} {version}".strip(),
                    "severity": "HIGH" if cves else "INFO",
                    "description": script_text.strip(),
                    "matched_at": f"{host}:{port_id}" if host else port_id,
                    "host": host,
                    "cve_ids": cves,
                    "cwe_ids": [],
                    "tags": ["nmap", svc_name],
                }
            )
    return findings


def parse_burp_xml(xml_text: str) -> list[dict[str, Any]]:
    """Parse Burp Suite XML issues export into normalized recon findings."""
    root = _safe_xml_root(xml_text)
    if root is None or root.tag != "issues":
        return []
    findings: list[dict[str, Any]] = []
    for issue in root.findall("issue"):
        name = (issue.findtext("name") or "Burp Issue").strip()
        host = (issue.findtext("host") or "").strip()
        path = (issue.findtext("path") or "").strip()
        severity = (issue.findtext("severity") or "information").strip().upper()
        detail = (issue.findtext("issueDetail") or issue.findtext("issueBackground") or "").strip()
        vuln_class = (issue.findtext("vulnerabilityClassifications") or "").strip()
        combined = f"{detail} {vuln_class}"
        cves = sorted({m.upper() for m in _CVE_RE.findall(combined)})
        cwes = sorted({m.upper() for m in _CWE_RE.findall(combined)})
        matched_at = f"{host.rstrip('/')}{path}" if host else path
        parsed = urlparse(matched_at) if "://" in matched_at else None
        clean_host = parsed.hostname if parsed and parsed.hostname else host
        findings.append(
            {
                "template_id": f"burp:{issue.findtext('type') or name}",
                "name": name,
                "severity": "INFO" if severity == "INFORMATION" else severity,
                "description": detail[:1000],
                "matched_at": matched_at,
                "host": clean_host or "",
                "cve_ids": cves,
                "cwe_ids": cwes,
                "tags": ["burp"],
            }
        )
    return findings


def parse_caido_output(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Parse Caido findings/requests JSON export into normalized recon findings."""
    findings: list[dict[str, Any]] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        title = str(item.get("title") or item.get("name") or item.get("reporter") or "Caido Finding")
        desc = str(item.get("description") or "")
        host = str(item.get("host") or "").strip()
        path = str(item.get("path") or item.get("url") or "").strip()
        matched_at = path or host
        if not host and "://" in matched_at:
            host = urlparse(matched_at).hostname or ""
        combined = f"{title} {desc}"
        findings.append(
            {
                "template_id": f"caido:{item.get('id') or title}",
                "name": title,
                "severity": str(item.get("severity") or "MEDIUM").upper(),
                "description": desc,
                "matched_at": matched_at,
                "host": host,
                "cve_ids": sorted({m.upper() for m in _CVE_RE.findall(combined)}),
                "cwe_ids": sorted({m.upper() for m in _CWE_RE.findall(combined)}),
                "tags": ["caido"],
            }
        )
    return findings


def parse_recon_output(raw: str | list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Auto-detect and parse Nuclei JSON/JSONL, Nmap XML, Burp XML, or Caido JSON."""
    if isinstance(raw, str):
        stripped = raw.lstrip()
        if stripped.startswith("<"):
            if "<nmaprun" in stripped[:300]:
                return parse_nmap_xml(stripped)
            if "<issues" in stripped[:300]:
                return parse_burp_xml(stripped)
            return []
        if stripped.startswith("["):
            try:
                loaded = json.loads(stripped)
                if (
                    isinstance(loaded, list)
                    and loaded
                    and isinstance(loaded[0], dict)
                    and "template-id" not in loaded[0]
                    and "templateID" not in loaded[0]
                ):
                    return parse_caido_output(loaded)
            except json.JSONDecodeError:
                return []
    elif (
        isinstance(raw, list)
        and raw
        and isinstance(raw[0], dict)
        and "template-id" not in raw[0]
        and "templateID" not in raw[0]
    ):
        return parse_caido_output(raw)
    return parse_nuclei_output(raw)


def _as_list(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value.strip()] if value.strip() else []
    if isinstance(value, list):
        return [str(v).strip() for v in value if str(v).strip()]
    return []


def parse_nuclei_output(raw: str | list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Parse Nuclei JSON array or JSONL text into normalized recon findings."""
    items: list[dict[str, Any]] = []
    if isinstance(raw, list):
        items = [x for x in raw if isinstance(x, dict)]
    elif isinstance(raw, str):
        text = raw.strip()
        if not text:
            return []
        if text.startswith("["):
            try:
                loaded = json.loads(text)
                if isinstance(loaded, list):
                    items = [x for x in loaded if isinstance(x, dict)]
            except json.JSONDecodeError:
                return []
        else:
            for line in text.splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                    if isinstance(obj, dict):
                        items.append(obj)
                except json.JSONDecodeError:
                    continue

    findings: list[dict[str, Any]] = []
    for item in items:
        raw_info = item.get("info")
        info: dict[str, Any] = raw_info if isinstance(raw_info, dict) else {}
        raw_cls = info.get("classification")
        classification: dict[str, Any] = raw_cls if isinstance(raw_cls, dict) else {}
        matched_at = str(item.get("matched-at") or item.get("host") or "").strip()
        parsed_url = urlparse(matched_at) if "://" in matched_at else None
        host = (
            (parsed_url.hostname or matched_at)
            if parsed_url is not None
            else str(item.get("host") or matched_at).split(":", 1)[0]
        )
        template_id = str(item.get("template-id") or item.get("templateID") or "unknown")
        cve_ids = [c.upper() for c in _as_list(classification.get("cve-id"))]
        cwe_ids = [c.upper() for c in _as_list(classification.get("cwe-id"))]
        findings.append(
            {
                "template_id": template_id,
                "name": str(info.get("name") or template_id),
                "severity": str(info.get("severity") or "info").upper(),
                "description": str(info.get("description") or ""),
                "matched_at": matched_at,
                "host": host,
                "cve_ids": cve_ids,
                "cwe_ids": cwe_ids,
                "tags": _as_list(info.get("tags")),
            }
        )
    return findings


def _recon_key(tenant_id: str, finding: dict[str, Any]) -> str:
    raw = f"{tenant_id}:{finding['template_id']}:{finding['matched_at']}"
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"veraxi:recon:{raw}"))


def index_recon_vectors(
    qdrant_client: Any,
    findings: list[dict[str, Any]],
    tenant_id: str = "default",
    collection_name: str | None = None,
) -> int:
    """Embed and upsert Nuclei recon findings into Qdrant."""
    if not findings:
        return 0
    from backend.config import get_config
    from backend.ingestion.chunk_embed import embed_text, embed_text_sparse

    col = collection_name or get_config().qdrant_collection_name
    vectors: list[list[float]] = []
    sparse_vectors: list[dict[str, Any]] = []
    payloads: list[dict[str, Any]] = []
    for f in findings:
        pid = _recon_key(tenant_id, f)
        f["qdrant_point_ids"] = [pid]
        text = (
            f"[Nuclei {f['severity']}] {f['template_id']} ({f['name']}) at "
            f"{f['matched_at']} — {f.get('description', '')}"
        )
        vectors.append(embed_text(text))
        sparse_vectors.append(embed_text_sparse(text))
        payloads.append(
            {
                "point_id": pid,
                "text": text,
                "title": f"{f['template_id']} @ {f['host']}",
                "template_id": f["template_id"],
                "severity": f["severity"],
                "host": f["host"],
                "matched_at": f["matched_at"],
                "cve_ids": list(f.get("cve_ids") or []),
                "cwe_ids": list(f.get("cwe_ids") or []),
                "source_type": "dast_nuclei",
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


def write_recon_findings(
    neo4j_client: Any,
    findings: list[dict[str, Any]],
    tenant_id: str = "default",
    qdrant_client: Any = None,
) -> dict[str, int]:
    """Persist Nuclei recon findings to Neo4j (and optionally Qdrant)."""
    if not findings:
        return {
            "findings_written": 0,
            "host_links": 0,
            "cve_links": 0,
            "cwe_links": 0,
            "vectors_written": 0,
        }

    vectors_written = 0
    if qdrant_client is not None:
        vectors_written = index_recon_vectors(qdrant_client, findings, tenant_id=tenant_id)

    finding_rows = []
    host_nodes: dict[str, dict[str, Any]] = {}
    host_edges = []
    cve_edges = []
    cwe_edges = []

    for f in findings:
        rkey = _recon_key(tenant_id, f)
        props: dict[str, Any] = {
            "id": rkey,
            "name": f"{f['template_id']}@{f['matched_at']}",
            "template_id": f["template_id"],
            "severity": f["severity"],
            "description": f.get("description", ""),
            "matched_at": f["matched_at"],
            "host": f["host"],
            "tenant_id": tenant_id,
        }
        if f.get("qdrant_point_ids"):
            props["qdrant_point_ids"] = list(f["qdrant_point_ids"])
        finding_rows.append({"recon_key": rkey, "properties": props})

        if f["host"]:
            hkey = f"{tenant_id}::TargetHost::{f['host']}"
            host_nodes.setdefault(
                hkey,
                {
                    "recon_key": hkey,
                    "properties": {"id": f["host"], "name": f["host"], "tenant_id": tenant_id},
                },
            )
            host_edges.append({"host_key": hkey, "recon_key": rkey, "tenant_id": tenant_id})
        for cve_id in f.get("cve_ids") or []:
            cve_edges.append(
                {
                    "recon_key": rkey,
                    "cve_key": f"{tenant_id}::CVE::{cve_id}",
                    "cve_id": cve_id,
                    "tenant_id": tenant_id,
                }
            )
        for cwe_id in f.get("cwe_ids") or []:
            cwe_edges.append(
                {
                    "recon_key": rkey,
                    "cwe_key": f"{tenant_id}::CWE::{cwe_id}",
                    "cwe_id": cwe_id,
                    "tenant_id": tenant_id,
                }
            )

    neo4j_client.execute_write(
        """
        UNWIND $rows AS row
        MERGE (n:ReconFinding {recon_key: row.recon_key})
        SET n += row.properties
        """,
        {"rows": finding_rows},
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
            MATCH (r:ReconFinding {recon_key: row.recon_key})
            MERGE (h)-[rel:EXPOSES_FINDING]->(r)
            SET rel.tenant_id = row.tenant_id
            """,
            {"rows": host_edges},
        )
    if cve_edges:
        neo4j_client.execute_write(
            """
            UNWIND $rows AS row
            MERGE (c:CVE {vuln_key: row.cve_key})
            ON CREATE SET c.id = row.cve_id, c.tenant_id = row.tenant_id
            WITH row, c
            MATCH (r:ReconFinding {recon_key: row.recon_key})
            MERGE (r)-[rel:DETECTS_CVE]->(c)
            SET rel.tenant_id = row.tenant_id
            """,
            {"rows": cve_edges},
        )
    if cwe_edges:
        neo4j_client.execute_write(
            """
            UNWIND $rows AS row
            MERGE (c:CWE {vuln_key: row.cwe_key})
            ON CREATE SET c.id = row.cwe_id, c.tenant_id = row.tenant_id
            WITH row, c
            MATCH (r:ReconFinding {recon_key: row.recon_key})
            MERGE (r)-[rel:HAS_WEAKNESS]->(c)
            SET rel.tenant_id = row.tenant_id
            """,
            {"rows": cwe_edges},
        )

    return {
        "findings_written": len(finding_rows),
        "host_links": len(host_edges),
        "cve_links": len(cve_edges),
        "cwe_links": len(cwe_edges),
        "vectors_written": vectors_written,
    }


__all__ = [
    "index_recon_vectors",
    "parse_burp_xml",
    "parse_caido_output",
    "parse_nmap_xml",
    "parse_nuclei_output",
    "parse_recon_output",
    "write_recon_findings",
]
