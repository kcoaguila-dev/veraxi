"""Vuln Intel: NVD / CISA KEV parsing, version matching and Neo4j writes.

Three separable halves, mirroring ``code_graph.py``:

* Pure parsers — :func:`parse_nvd_payload` (NVD API 2.0 JSON),
  :func:`parse_kev_payload` (CISA KEV JSON) and :func:`parse_kev_csv`
  (KEV CSV export). They operate on already-parsed payloads / text, so
  tests need no network.
* Conservative version matching — :func:`parse_version` /
  :func:`version_in_range`. Only plain numeric dotted versions are
  comparable. FAIL CLOSED: an unparseable installed version, an
  unparseable range bound, or a range with no usable bound yields
  ``"unknown"``, never ``"matched"``.
* Persistence — :func:`write_vuln_records` writes CVE / CWE / Package
  nodes through the storage client with parameterized Cypher only,
  following ``graph_write.py`` / ``code_graph.py`` patterns.

Tenant convention: vulnerability intelligence is shared public data,
but — like the code graph — it is written under the *requesting
tenant* (``tenant_id`` is stamped on every node and edge, and node
keys are tenant-prefixed). That keeps reads tenant-scoped and
consistent with Phase 3, at the cost of duplicating the public corpus
per tenant that ingests it. No cross-tenant reads happen here.

Fetch layer: :func:`fetch_nvd_records` / :func:`fetch_kev_records`
are thin ``httpx`` wrappers over the public NVD API 2.0 and the CISA
KEV JSON feed. The optional NVD API key is read only from the
``NVD_API_KEY`` environment variable (or an explicit argument); it is
never hardcoded. Tests inject a mock-transport ``httpx.Client`` — no
network in tests.

Graph model:

* ``CVE`` nodes: ``id``, ``description``, ``severity``, ``cvss_score``,
  ``published``, ``last_modified``, ``kev`` (bool), ``kev_date``.
* ``CWE`` nodes: ``id`` (e.g. ``CWE-79``).
* ``Package`` nodes: ``name`` (normalized), ``vendor``, ``ecosystem``
  (``"cpe"`` for NVD-derived packages, the OSV ecosystem name such as
  ``"PyPI"`` / ``"npm"`` / ``"Maven"`` for OSV-derived packages).
  Package nodes are keyed by ``(ecosystem, normalized_name)`` so the
  same name in different ecosystems never collides.
* Edges: ``CVE -[:HAS_WEAKNESS]-> CWE`` and
  ``CVE -[:AFFECTS]-> Package`` with the CPE version-range properties
  (``criteria``, ``version_start_including``,
  ``version_start_excluding``, ``version_end_including``,
  ``version_end_excluding``, ``criteria_version``, ``vulnerable``)
  stored on the AFFECTS edge so the join can re-evaluate ranges.
"""

from __future__ import annotations

import csv
import io
import logging
import os
import re
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from typing import Any

import httpx

logger = logging.getLogger(__name__)

NVD_API_URL = "https://services.nvd.nist.gov/rest/json/cves/2.0"
OSV_API_URL = "https://api.osv.dev/v1"
OSV_BATCH_URL = f"{OSV_API_URL}/querybatch"

# Veraxi / dependency-extractor ecosystem names (lowercase, see
# ``ingestion/dependencies.py``) -> OSV ecosystem names. Canonical OSV
# names are also accepted unchanged (case-insensitive lookup).
OSV_ECOSYSTEM_MAP = {
    "pypi": "PyPI",
    "pip": "PyPI",
    "npm": "npm",
    "maven": "Maven",
    "pub": "Pub",
    "go": "Go",
    "cargo": "crates.io",
    "crates.io": "crates.io",
    "crates": "crates.io",
    "cpe": "cpe",
}
KEV_JSON_URL = (
    "https://www.cisa.gov/sites/default/files/feeds/"
    "known_exploited_vulnerabilities.json"
)

NODE_LABELS = ("CVE", "CWE", "Package")
EDGE_TYPES = ("HAS_WEAKNESS", "AFFECTS")

_VERSION_RE = re.compile(r"^\d+(?:\.\d+)*$")


# ---------------------------------------------------------------------------
# Version comparison (conservative, fail closed)
# ---------------------------------------------------------------------------


def parse_version(version: str | None) -> tuple[int, ...] | None:
    """Parse a plain numeric dotted version, or ``None`` if unparseable.

    A leading ``v`` is tolerated. Anything with pre-release / build
    suffixes, wildcards or non-numeric components is unparseable —
    callers must treat that as unknown, never as a match.
    """
    if version is None:
        return None
    text = str(version).strip()
    if text.startswith(("v", "V")):
        text = text[1:]
    if not _VERSION_RE.match(text):
        return None
    return tuple(int(part) for part in text.split("."))


def compare_versions(left: str | None, right: str | None) -> int | None:
    """-1/0/1 comparison, or ``None`` when either side is unparseable."""
    parsed_left, parsed_right = parse_version(left), parse_version(right)
    if parsed_left is None or parsed_right is None:
        return None
    width = max(len(parsed_left), len(parsed_right))
    padded_left = parsed_left + (0,) * (width - len(parsed_left))
    padded_right = parsed_right + (0,) * (width - len(parsed_right))
    if padded_left < padded_right:
        return -1
    if padded_left > padded_right:
        return 1
    return 0


@dataclass
class VersionRange:
    """One CPE match entry: a product plus its affected version range."""

    criteria: str = ""
    vendor: str = ""
    product: str = ""
    criteria_version: str = ""
    vulnerable: bool = True
    version_start_including: str | None = None
    version_start_excluding: str | None = None
    version_end_including: str | None = None
    version_end_excluding: str | None = None
    # OSV-derived ranges: the ecosystem of ``product`` and the raw
    # OSV ``introduced`` / ``fixed`` range events (mirrored into the
    # version_start_including / version_end_excluding fields above so
    # the fail-closed comparator above applies unchanged).
    ecosystem: str = ""
    introduced: str | None = None
    fixed: str | None = None

    def properties(self) -> dict[str, Any]:
        return {
            "criteria": self.criteria,
            "criteria_version": self.criteria_version,
            "vulnerable": self.vulnerable,
            "version_start_including": self.version_start_including,
            "version_start_excluding": self.version_start_excluding,
            "version_end_including": self.version_end_including,
            "version_end_excluding": self.version_end_excluding,
            "ecosystem": self.ecosystem,
            "introduced": self.introduced,
            "fixed": self.fixed,
        }


def version_in_range(version: str | None, version_range: VersionRange) -> str:
    """Classify ``version`` against ``version_range``.

    Returns ``"matched"``, ``"not_matched"`` or ``"unknown"``. Unknown
    is returned whenever a confident decision is impossible: the
    installed version is missing/unparseable, a stated bound is
    unparseable, the CPE entry is not marked vulnerable has already
    been handled by the caller, or the entry carries neither bounds
    nor a concrete criteria version.
    """
    if not version_range.vulnerable:
        return "not_matched"
    if parse_version(version) is None:
        return "unknown"
    bounds = (
        version_range.version_start_including,
        version_range.version_start_excluding,
        version_range.version_end_including,
        version_range.version_end_excluding,
    )
    if all(bound is None for bound in bounds):
        criteria_version = version_range.criteria_version
        if not criteria_version or criteria_version in ("*", "-"):
            return "unknown"
        comparison = compare_versions(version, criteria_version)
        if comparison is None:
            return "unknown"
        return "matched" if comparison == 0 else "not_matched"
    checks: list[bool] = []
    start_incl = version_range.version_start_including
    if start_incl is not None:
        comparison = compare_versions(version, start_incl)
        if comparison is None:
            return "unknown"
        checks.append(comparison >= 0)
    start_excl = version_range.version_start_excluding
    if start_excl is not None:
        comparison = compare_versions(version, start_excl)
        if comparison is None:
            return "unknown"
        checks.append(comparison > 0)
    end_incl = version_range.version_end_including
    if end_incl is not None:
        comparison = compare_versions(version, end_incl)
        if comparison is None:
            return "unknown"
        checks.append(comparison <= 0)
    end_excl = version_range.version_end_excluding
    if end_excl is not None:
        comparison = compare_versions(version, end_excl)
        if comparison is None:
            return "unknown"
        checks.append(comparison < 0)
    return "matched" if all(checks) else "not_matched"


# ---------------------------------------------------------------------------
# Records
# ---------------------------------------------------------------------------


@dataclass
class CVERecord:
    """One parsed CVE with its weaknesses and affected packages."""

    id: str
    description: str = ""
    severity: str | None = None
    cvss_score: float | None = None
    published: str | None = None
    last_modified: str | None = None
    cwe_ids: list[str] = field(default_factory=list)
    affected: list[VersionRange] = field(default_factory=list)
    # Advisory aliases (e.g. a GHSA-/PYSEC- record's CVE-* alias) so
    # KEV enrichment can match OSV records whose primary id is not a CVE.
    aliases: list[str] = field(default_factory=list)
    kev: bool = False
    kev_date: str | None = None

    def properties(self, tenant_id: str) -> dict[str, Any]:
        return {
            "id": self.id,
            "description": self.description,
            "severity": self.severity,
            "cvss_score": self.cvss_score,
            "published": self.published,
            "last_modified": self.last_modified,
            "kev": self.kev,
            "kev_date": self.kev_date,
            "aliases": list(self.aliases),
            "tenant_id": tenant_id,
        }


# ---------------------------------------------------------------------------
# NVD API 2.0 parsing (pure)
# ---------------------------------------------------------------------------


def _english_description(descriptions: Any) -> str:
    for entry in descriptions or []:
        if entry.get("lang") == "en":
            return entry.get("value", "") or ""
    for entry in descriptions or []:
        return entry.get("value", "") or ""
    return ""


def _extract_cwe_ids(weaknesses: Any) -> list[str]:
    cwe_ids: list[str] = []
    for weakness in weaknesses or []:
        for entry in weakness.get("description") or []:
            value = (entry.get("value") or "").strip()
            if value.startswith("CWE-") and value not in cwe_ids:
                cwe_ids.append(value)
    return cwe_ids


def _extract_severity(metrics: Any) -> tuple[str | None, float | None]:
    metrics = metrics or {}
    for key in ("cvssMetricV31", "cvssMetricV30", "cvssMetricV2"):
        entries = metrics.get(key) or []
        if not entries:
            continue
        ordered = sorted(
            entries, key=lambda e: 0 if e.get("type") == "Primary" else 1
        )
        cvss_data = ordered[0].get("cvssData") or {}
        severity = cvss_data.get("baseSeverity") or ordered[0].get("baseSeverity")
        score = cvss_data.get("baseScore")
        return severity, float(score) if score is not None else None
    return None, None


def _parse_cpe(criteria: str) -> tuple[str, str, str]:
    """Split a CPE 2.3 criteria string into (vendor, product, version)."""
    parts = (criteria or "").split(":")
    # cpe:2.3:<part>:<vendor>:<product>:<version>:...
    vendor = parts[3] if len(parts) > 3 else ""
    product = parts[4] if len(parts) > 4 else ""
    version = parts[5] if len(parts) > 5 else ""
    return vendor, product, version


def _collect_cpe_matches(nodes: Any) -> list[dict[str, Any]]:
    matches: list[dict[str, Any]] = []
    for node in nodes or []:
        matches.extend(node.get("cpeMatch") or [])
        matches.extend(_collect_cpe_matches(node.get("children")))
    return matches


def _extract_affected(configurations: Any) -> list[VersionRange]:
    affected: list[VersionRange] = []
    for config in configurations or []:
        for match in _collect_cpe_matches(config.get("nodes")):
            criteria = match.get("criteria", "") or ""
            vendor, product, version = _parse_cpe(criteria)
            if not product:
                continue
            affected.append(
                VersionRange(
                    criteria=criteria,
                    vendor=vendor,
                    product=product,
                    criteria_version=version,
                    vulnerable=bool(match.get("vulnerable", True)),
                    version_start_including=match.get("versionStartIncluding"),
                    version_start_excluding=match.get("versionStartExcluding"),
                    version_end_including=match.get("versionEndIncluding"),
                    version_end_excluding=match.get("versionEndExcluding"),
                )
            )
    return affected


def parse_nvd_payload(payload: dict) -> list[CVERecord]:
    """Parse an NVD API 2.0 response payload into :class:`CVERecord`s.

    Pure function over the already-decoded JSON body
    (``vulnerabilities[].cve``). Malformed entries are skipped.
    """
    records: list[CVERecord] = []
    for item in (payload or {}).get("vulnerabilities") or []:
        cve = (item or {}).get("cve") or {}
        cve_id = cve.get("id")
        if not cve_id:
            continue
        severity, score = _extract_severity(cve.get("metrics"))
        records.append(
            CVERecord(
                id=cve_id,
                description=_english_description(cve.get("descriptions")),
                severity=severity,
                cvss_score=score,
                published=cve.get("published"),
                last_modified=cve.get("lastModified"),
                cwe_ids=_extract_cwe_ids(cve.get("weaknesses")),
                affected=_extract_affected(cve.get("configurations")),
            )
        )
    return records


# ---------------------------------------------------------------------------
# CISA KEV parsing (pure; JSON + CSV shapes)
# ---------------------------------------------------------------------------


def parse_kev_payload(payload: dict) -> list[dict[str, Any]]:
    """Parse the CISA KEV JSON feed into plain record dicts."""
    records: list[dict[str, Any]] = []
    for entry in (payload or {}).get("vulnerabilities") or []:
        cve_id = entry.get("cveID")
        if not cve_id:
            continue
        records.append(
            {
                "cve_id": cve_id,
                "vendor_project": entry.get("vendorProject", ""),
                "product": entry.get("product", ""),
                "vulnerability_name": entry.get("vulnerabilityName", ""),
                "date_added": entry.get("dateAdded"),
                "known_ransomware_campaign_use": entry.get(
                    "knownRansomwareCampaignUse", ""
                ),
                "description": entry.get("shortDescription", ""),
            }
        )
    return records


def parse_kev_csv(text: str) -> list[dict[str, Any]]:
    """Parse the CISA KEV CSV export (same fields, CSV headers)."""
    records: list[dict[str, Any]] = []
    reader = csv.DictReader(io.StringIO(text or ""))
    for row in reader:
        cve_id = (row.get("cveID") or "").strip()
        if not cve_id:
            continue
        records.append(
            {
                "cve_id": cve_id,
                "vendor_project": (row.get("vendorProject") or "").strip(),
                "product": (row.get("product") or "").strip(),
                "vulnerability_name": (row.get("vulnerabilityName") or "").strip(),
                "date_added": (row.get("dateAdded") or "").strip() or None,
                "known_ransomware_campaign_use": (
                    row.get("knownRansomwareCampaignUse") or ""
                ).strip(),
                "description": (row.get("shortDescription") or "").strip(),
            }
        )
    return records


def apply_kev(records: list[CVERecord], kev_records: list[dict[str, Any]]) -> list[CVERecord]:
    """Mark CVE records that appear in the KEV catalogue (mutates + returns).

    A record matches when its own id *or any of its aliases* is a KEV
    CVE id — OSV advisories are often keyed by GHSA-/PYSEC- ids whose
    CVE id only appears in ``aliases``.
    """
    kev_by_id = {entry["cve_id"]: entry for entry in kev_records}
    for record in records:
        kev_entry = kev_by_id.get(record.id)
        if kev_entry is None:
            for alias in record.aliases:
                kev_entry = kev_by_id.get(alias)
                if kev_entry is not None:
                    break
        if kev_entry is not None:
            record.kev = True
            record.kev_date = kev_entry.get("date_added")
    return records


# ---------------------------------------------------------------------------
# Neo4j writer (code_graph.py patterns: tenant-scoped, parameterized)
# ---------------------------------------------------------------------------


def _vuln_key(tenant_id: str, label: str, identifier: str) -> str:
    return f"{tenant_id}::{label}::{identifier}"


def _package_ecosystem(affected: VersionRange) -> str:
    """Ecosystem for a package node: OSV ecosystem, or ``"cpe"`` for NVD."""
    return affected.ecosystem or "cpe"


def _package_key(tenant_id: str, affected: VersionRange, package_name: str) -> str:
    """Package node key: ``(ecosystem, normalized_name)`` scoped to tenant."""
    return _vuln_key(
        tenant_id, "Package", f"{_package_ecosystem(affected)}:{package_name}"
    )


def _write_cve(client: Any, record: CVERecord, tenant_id: str) -> None:
    query = """
    MERGE (n:CVE {vuln_key: $vuln_key})
    SET n += $properties
    """
    properties = record.properties(tenant_id)
    properties["vuln_key"] = _vuln_key(tenant_id, "CVE", record.id)
    client.execute_write(
        query, {"vuln_key": properties["vuln_key"], "properties": properties}
    )


def _write_cwe_link(client: Any, record: CVERecord, cwe_id: str, tenant_id: str) -> None:
    node_query = """
    MERGE (n:CWE {vuln_key: $vuln_key})
    SET n += $properties
    """
    properties = {"id": cwe_id, "tenant_id": tenant_id}
    properties["vuln_key"] = _vuln_key(tenant_id, "CWE", cwe_id)
    client.execute_write(
        node_query, {"vuln_key": properties["vuln_key"], "properties": properties}
    )
    edge_query = """
    MATCH (a {vuln_key: $from_key})
    MATCH (b {vuln_key: $to_key})
    MERGE (a)-[r:HAS_WEAKNESS]->(b)
    SET r.tenant_id = $tenant_id
    """
    client.execute_write(
        edge_query,
        {
            "from_key": _vuln_key(tenant_id, "CVE", record.id),
            "to_key": _vuln_key(tenant_id, "CWE", cwe_id),
            "tenant_id": tenant_id,
        },
    )


def _write_affects_link(
    client: Any, record: CVERecord, affected: VersionRange, tenant_id: str
) -> None:
    from backend.ingestion.dependencies import normalize_package_name

    package_name = normalize_package_name(affected.product)
    node_query = """
    MERGE (n:Package {vuln_key: $vuln_key})
    SET n += $properties
    """
    properties = {
        "name": package_name,
        "vendor": affected.vendor,
        "ecosystem": _package_ecosystem(affected),
        "tenant_id": tenant_id,
    }
    properties["vuln_key"] = _package_key(tenant_id, affected, package_name)
    client.execute_write(
        node_query, {"vuln_key": properties["vuln_key"], "properties": properties}
    )
    edge_query = """
    MATCH (a {vuln_key: $from_key})
    MATCH (b {vuln_key: $to_key})
    MERGE (a)-[r:AFFECTS {criteria: $criteria}]->(b)
    SET r += $properties, r.tenant_id = $tenant_id
    """
    properties = affected.properties()
    client.execute_write(
        edge_query,
        {
            "from_key": _vuln_key(tenant_id, "CVE", record.id),
            "to_key": _package_key(tenant_id, affected, package_name),
            "criteria": affected.criteria,
            "properties": properties,
            "tenant_id": tenant_id,
        },
    )


def write_vuln_records(
    client: Any,
    records: list[CVERecord],
    tenant_id: str = "default",
    kev_records: list[dict[str, Any]] | None = None,
) -> dict[str, int]:
    """Persist parsed CVE records to Neo4j via ``client``.

    ``client`` is the existing Neo4j storage client (anything exposing
    ``execute_write(query, parameters)``). Every query is
    parameterized; labels/relationship types are fixed literals in
    this module. When ``kev_records`` are given they are applied to
    the CVE records first. Vuln nodes are public reference data, NOT
    text chunks, so — like code-graph nodes — they carry no Qdrant
    point ID. Returns write counts.
    """
    if kev_records:
        apply_kev(records, kev_records)
    cwe_links = 0
    affects_links = 0
    for record in records:
        _write_cve(client, record, tenant_id)
        for cwe_id in record.cwe_ids:
            _write_cwe_link(client, record, cwe_id, tenant_id)
            cwe_links += 1
        for affected in record.affected:
            _write_affects_link(client, record, affected, tenant_id)
            affects_links += 1
    return {
        "cves_written": len(records),
        "cwe_links_written": cwe_links,
        "affects_links_written": affects_links,
    }


def write_vuln_records_batch(
    client: Any,
    records: list[CVERecord],
    tenant_id: str = "default",
    kev_records: list[dict[str, Any]] | None = None,
) -> dict[str, int]:
    """Batch-persist parsed CVE records to Neo4j via ``UNWIND`` queries.

    Reduces N+1 round-trips in ``vuln sync`` to at most 5 parameterized
    writes regardless of record count.
    """
    if kev_records:
        apply_kev(records, kev_records)
    if not records:
        return {"cves_written": 0, "cwe_links_written": 0, "affects_links_written": 0}

    from backend.ingestion.dependencies import normalize_package_name

    cve_rows = []
    cwe_nodes: dict[str, dict[str, Any]] = {}
    cwe_edges = []
    pkg_nodes: dict[str, dict[str, Any]] = {}
    affects_edges = []

    for record in records:
        cve_key = _vuln_key(tenant_id, "CVE", record.id)
        props = record.properties(tenant_id)
        props["vuln_key"] = cve_key
        cve_rows.append({"vuln_key": cve_key, "properties": props})

        for cwe_id in record.cwe_ids:
            cwe_key = _vuln_key(tenant_id, "CWE", cwe_id)
            cwe_nodes.setdefault(
                cwe_key,
                {"vuln_key": cwe_key, "properties": {"id": cwe_id, "tenant_id": tenant_id, "vuln_key": cwe_key}},
            )
            cwe_edges.append({"from_key": cve_key, "to_key": cwe_key, "tenant_id": tenant_id})

        for affected in record.affected:
            pkg_name = normalize_package_name(affected.product)
            pkg_key = _package_key(tenant_id, affected, pkg_name)
            pkg_nodes.setdefault(
                pkg_key,
                {
                    "vuln_key": pkg_key,
                    "properties": {
                        "name": pkg_name,
                        "vendor": affected.vendor,
                        "ecosystem": _package_ecosystem(affected),
                        "tenant_id": tenant_id,
                        "vuln_key": pkg_key,
                    },
                },
            )
            affects_edges.append(
                {
                    "from_key": cve_key,
                    "to_key": pkg_key,
                    "criteria": affected.criteria,
                    "properties": affected.properties(),
                    "tenant_id": tenant_id,
                }
            )

    client.execute_write(
        "UNWIND $rows AS row MERGE (n:CVE {vuln_key: row.vuln_key}) SET n += row.properties",
        {"rows": cve_rows},
    )
    if cwe_nodes:
        client.execute_write(
            "UNWIND $rows AS row MERGE (n:CWE {vuln_key: row.vuln_key}) SET n += row.properties",
            {"rows": list(cwe_nodes.values())},
        )
        client.execute_write(
            "UNWIND $rows AS row MATCH (a {vuln_key: row.from_key}) MATCH (b {vuln_key: row.to_key}) "
            "MERGE (a)-[r:HAS_WEAKNESS]->(b) SET r.tenant_id = row.tenant_id",
            {"rows": cwe_edges},
        )
    if pkg_nodes:
        client.execute_write(
            "UNWIND $rows AS row MERGE (n:Package {vuln_key: row.vuln_key}) SET n += row.properties",
            {"rows": list(pkg_nodes.values())},
        )
        client.execute_write(
            "UNWIND $rows AS row MATCH (a {vuln_key: row.from_key}) MATCH (b {vuln_key: row.to_key}) "
            "MERGE (a)-[r:AFFECTS {criteria: row.criteria}]->(b) SET r += row.properties, r.tenant_id = row.tenant_id",
            {"rows": affects_edges},
        )

    return {
        "cves_written": len(cve_rows),
        "cwe_links_written": len(cwe_edges),
        "affects_links_written": len(affects_edges),
    }



# ---------------------------------------------------------------------------
# OSV.dev parsing + fetch (pure parser; fetch via injected httpx client)
# ---------------------------------------------------------------------------


def osv_ecosystem(ecosystem: str | None) -> str | None:
    """Map a Veraxi ecosystem name to its OSV ecosystem name, or None."""
    if not ecosystem:
        return None
    return OSV_ECOSYSTEM_MAP.get(str(ecosystem).strip().lower())


def _osv_ranges(affected_entry: dict[str, Any], package: dict[str, Any]) -> list[VersionRange]:
    """Convert one OSV ``affected`` entry into VersionRange objects."""
    name = package.get("name", "") or ""
    ecosystem = package.get("ecosystem", "") or ""
    ranges: list[VersionRange] = []
    for rng in affected_entry.get("ranges") or []:
        if rng.get("type") not in (None, "ECOSYSTEM", "SEMVER"):
            continue
        introduced: str | None = None
        for event in rng.get("events") or []:
            if "introduced" in event:
                if introduced is not None:
                    ranges.append(_osv_range(name, ecosystem, introduced, None, None))
                introduced = event.get("introduced")
            elif "fixed" in event:
                ranges.append(_osv_range(name, ecosystem, introduced, event.get("fixed"), None))
                introduced = None
            elif "last_affected" in event:
                ranges.append(_osv_range(name, ecosystem, introduced, None, event.get("last_affected")))
                introduced = None
        if introduced is not None:
            ranges.append(_osv_range(name, ecosystem, introduced, None, None))
    for version in affected_entry.get("versions") or []:
        ranges.append(
            VersionRange(
                criteria=f"osv:{ecosystem}:{name}:{version}",
                product=name,
                criteria_version=str(version),
                vulnerable=True,
                ecosystem=ecosystem,
            )
        )
    return ranges


def _osv_range(
    name: str,
    ecosystem: str,
    introduced: str | None,
    fixed: str | None,
    last_affected: str | None,
) -> VersionRange:
    start = introduced if introduced and introduced != "0" else None
    return VersionRange(
        criteria=f"osv:{ecosystem}:{name}:{introduced or ''}-{fixed or last_affected or ''}",
        product=name,
        vulnerable=True,
        version_start_including=start,
        version_end_excluding=fixed,
        version_end_including=last_affected,
        ecosystem=ecosystem,
        introduced=introduced,
        fixed=fixed,
    )


def parse_osv_payload(payload: dict[str, Any]) -> CVERecord | None:
    """Parse one OSV advisory document (``GET /v1/vulns/{id}`` shape)."""
    if not payload or not payload.get("id"):
        return None
    aliases = [a for a in (payload.get("aliases") or []) if a]
    severity = None
    db_specific = payload.get("database_specific") or {}
    if isinstance(db_specific.get("severity"), str):
        severity = db_specific["severity"].upper()
    cwe_ids = [c for c in (db_specific.get("cwe_ids") or []) if str(c).startswith("CWE-")]
    affected: list[VersionRange] = []
    for entry in payload.get("affected") or []:
        affected.extend(_osv_ranges(entry, entry.get("package") or {}))
    return CVERecord(
        id=payload["id"],
        description=payload.get("summary") or payload.get("details") or "",
        severity=severity,
        published=payload.get("published"),
        last_modified=payload.get("modified"),
        cwe_ids=cwe_ids,
        affected=affected,
        aliases=aliases,
    )


def _osv_queries(packages: list[dict[str, Any]]) -> list[dict[str, Any] | None]:
    """Build OSV querybatch queries; None marks an unmappable package."""
    queries: list[dict[str, Any] | None] = []
    for package in packages or []:
        ecosystem = osv_ecosystem(package.get("ecosystem"))
        name = (package.get("name") or "").strip()
        version = package.get("version")
        if not ecosystem or ecosystem == "cpe" or not name or not version:
            queries.append(None)
            continue
        queries.append(
            {"package": {"name": name, "ecosystem": ecosystem}, "version": str(version)}
        )
    return queries


def fetch_osv_for_packages(
    packages: list[dict[str, Any]],
    client: httpx.Client | None = None,
) -> list[CVERecord]:
    """Batch-query OSV.dev for ``packages`` and hydrate full advisories.

    ``packages`` are dependency records (``name`` / ``version`` /
    ``ecosystem``). Queries are POSTed to ``/v1/querybatch`` in chunks
    of at most 1000; each returned advisory id is then hydrated via
    ``GET /v1/vulns/{id}`` and parsed with :func:`parse_osv_payload`.
    Packages whose ecosystem has no OSV mapping, or that carry no
    concrete version, are skipped (fail closed — no version, no query).
    Tests inject a mock-transport ``httpx.Client``; no key is needed.
    """
    queries = _osv_queries(packages)
    valid = [q for q in queries if q is not None]
    if not valid:
        return []
    own_client = client is None
    http_client = client or httpx.Client(timeout=30.0)
    try:
        vuln_ids: list[str] = []
        for start in range(0, len(valid), 1000):
            chunk = valid[start : start + 1000]
            response = http_client.post(OSV_BATCH_URL, json={"queries": chunk})
            response.raise_for_status()
            for result in (response.json() or {}).get("results") or []:
                for vuln in (result or {}).get("vulns") or []:
                    vuln_id = vuln.get("id")
                    if vuln_id and vuln_id not in vuln_ids:
                        vuln_ids.append(vuln_id)
        records: list[CVERecord] = []
        for vuln_id in vuln_ids:
            detail = http_client.get(f"{OSV_API_URL}/vulns/{vuln_id}")
            detail.raise_for_status()
            record = parse_osv_payload(detail.json() or {})
            if record is not None:
                records.append(record)
        return records
    finally:
        if own_client:
            http_client.close()


# ---------------------------------------------------------------------------
# Fetch layer (thin httpx wrappers; tests inject a mock-transport client)
# ---------------------------------------------------------------------------


def _default_nvd_params(days: int = 30, results_per_page: int = 100) -> dict[str, Any]:
    """Return bounded NVD query params for recent CVEs."""
    end = datetime.now(UTC)
    start = end - timedelta(days=days)
    fmt = "%Y-%m-%dT%H:%M:%S.000Z"
    return {
        "resultsPerPage": results_per_page,
        "lastModStartDate": start.strftime(fmt),
        "lastModEndDate": end.strftime(fmt),
    }


def fetch_nvd_records(
    client: httpx.Client | None = None,
    api_key: str | None = None,
    extra_params: dict[str, Any] | None = None,
) -> list[CVERecord]:
    """GET the NVD API 2.0 CVE endpoint and parse the response.

    The API key comes from the ``NVD_API_KEY`` environment variable
    unless explicitly passed; it is sent as the ``apiKey`` header and
    never hardcoded or logged.
    """
    key = api_key if api_key is not None else os.environ.get("NVD_API_KEY")
    headers = {"apiKey": key} if key else {}
    params = extra_params if extra_params is not None else _default_nvd_params()
    own_client = client is None
    http_client = client or httpx.Client(timeout=30.0)
    try:
        response = http_client.get(
            NVD_API_URL, headers=headers, params=params
        )
        response.raise_for_status()
        return parse_nvd_payload(response.json())
    finally:
        if own_client:
            http_client.close()


def fetch_kev_records(client: httpx.Client | None = None) -> list[dict[str, Any]]:
    """GET the CISA KEV JSON feed and parse it into record dicts."""
    own_client = client is None
    http_client = client or httpx.Client(timeout=30.0)
    try:
        response = http_client.get(KEV_JSON_URL)
        response.raise_for_status()
        return parse_kev_payload(response.json())
    finally:
        if own_client:
            http_client.close()


def fetch_and_write_vuln_intel(
    client: Any,
    tenant_id: str = "default",
    http_client: httpx.Client | None = None,
    api_key: str | None = None,
) -> dict[str, int]:
    """Fetch NVD + KEV data and write it for ``tenant_id``."""
    records = fetch_nvd_records(client=http_client, api_key=api_key)
    kev_records = fetch_kev_records(client=http_client)
    return write_vuln_records_batch(
        client, records, tenant_id=tenant_id, kev_records=kev_records
    )


__all__ = [
    "EDGE_TYPES",
    "KEV_JSON_URL",
    "NODE_LABELS",
    "NVD_API_URL",
    "OSV_API_URL",
    "OSV_BATCH_URL",
    "OSV_ECOSYSTEM_MAP",
    "CVERecord",
    "VersionRange",
    "apply_kev",
    "compare_versions",
    "fetch_and_write_vuln_intel",
    "fetch_kev_records",
    "fetch_nvd_records",
    "fetch_osv_for_packages",
    "osv_ecosystem",
    "parse_kev_csv",
    "parse_kev_payload",
    "parse_nvd_payload",
    "parse_osv_payload",
    "parse_version",
    "version_in_range",
    "write_vuln_records",
    "write_vuln_records_batch",
]
