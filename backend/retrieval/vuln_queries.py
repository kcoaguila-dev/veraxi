"""Vuln Intel query layer: join extracted dependencies against CVE data.

The join itself — :func:`match_dependencies` — is a pure function over
``(dependencies, affected_index)`` so it is testable without a
database. ``affected_index`` maps a normalized package name to a list
of affected entries, each a dict with the AFFECTS-edge shape written
by :mod:`backend.ingestion.vuln_intel`::

    {"cve_id", "severity", "kev", "cwe_ids", "criteria",
     "criteria_version", "vulnerable", "version_start_including",
     "version_start_excluding", "version_end_including",
     "version_end_excluding"}

Match semantics (conservative, fail closed — see
``vuln_intel.version_in_range``):

* ``"matched"`` — the dependency's concrete/base version is provably
  inside the CVE's affected range;
* ``"unknown"`` — a CVE affects the package but the version or range
  cannot be parsed confidently, so vulnerability is neither claimed
  nor ruled out;
* versions provably outside the range produce no finding at all.

The DB-backed path reads CVE/AFFECTS data through an injectable
:class:`VulnGraphClient` protocol, exactly like Phase 3's
``code_queries``; the production adapter issues parameterized Cypher
only. Version-range evaluation deliberately reuses the ingestion
module's pure comparator logic via a local re-implementation of its
semantics — retrieval must not import ingestion (pipeline direction:
both depend on storage only), so the small comparator is duplicated
here rather than shared. Keep the two in sync: both fail closed.
"""

from __future__ import annotations

import logging
import re
from typing import Any, Protocol, runtime_checkable

logger = logging.getLogger(__name__)

_VERSION_RE = re.compile(r"^\d+(?:\.\d+)*$")


def _normalize_package_name(name: str) -> str:
    cleaned = (name or "").strip().lower()
    if "/" in cleaned and cleaned.startswith("@"):
        return cleaned
    return re.sub(r"[-_.]+", "-", cleaned)


def _parse_version(version: str | None) -> tuple[int, ...] | None:
    if version is None:
        return None
    text = str(version).strip()
    if text.startswith(("v", "V")):
        text = text[1:]
    if not _VERSION_RE.match(text):
        return None
    return tuple(int(part) for part in text.split("."))


def _compare_versions(left: str | None, right: str | None) -> int | None:
    parsed_left, parsed_right = _parse_version(left), _parse_version(right)
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


def _entry_match_status(version: str | None, entry: dict[str, Any]) -> str:
    """Classify one dependency version against one AFFECTS entry."""
    if not entry.get("vulnerable", True):
        return "not_matched"
    if _parse_version(version) is None:
        return "unknown"
    bounds = {
        "start_incl": entry.get("version_start_including"),
        "start_excl": entry.get("version_start_excluding"),
        "end_incl": entry.get("version_end_including"),
        "end_excl": entry.get("version_end_excluding"),
    }
    if all(value is None for value in bounds.values()):
        criteria_version = entry.get("criteria_version") or ""
        if not criteria_version or criteria_version in ("*", "-"):
            return "unknown"
        comparison = _compare_versions(version, criteria_version)
        if comparison is None:
            return "unknown"
        return "matched" if comparison == 0 else "not_matched"
    checks: list[bool] = []
    comparisons = (
        (bounds["start_incl"], lambda c: c >= 0),
        (bounds["start_excl"], lambda c: c > 0),
        (bounds["end_incl"], lambda c: c <= 0),
        (bounds["end_excl"], lambda c: c < 0),
    )
    for bound, predicate in comparisons:
        if bound is None:
            continue
        comparison = _compare_versions(version, bound)
        if comparison is None:
            return "unknown"
        checks.append(predicate(comparison))
    return "matched" if all(checks) else "not_matched"


def match_dependencies(
    dependencies: list[dict[str, Any]],
    affected_index: dict[str, list[dict[str, Any]]],
) -> list[dict[str, Any]]:
    """Pure join: which dependencies have known CVEs?

    ``dependencies`` are records from
    ``backend.ingestion.dependencies`` (``name`` / ``version`` /
    ``ecosystem`` / ``source_file``). Returns one finding per
    (dependency, CVE) pair that is ``matched`` or ``unknown``;
    provably-unaffected pairs are omitted.
    """
    findings: list[dict[str, Any]] = []
    for dependency in dependencies:
        normalized = _normalize_package_name(dependency.get("name", ""))
        entries = affected_index.get(normalized) or []
        version = dependency.get("version")
        seen_cves: set[str] = set()
        for entry in entries:
            cve_id = entry.get("cve_id")
            if not cve_id:
                continue
            status = _entry_match_status(version, entry)
            if status == "not_matched":
                continue
            # One finding per CVE per dependency: a confident match
            # wins over an unknown from another range of the same CVE.
            if cve_id in seen_cves:
                if status == "matched":
                    for finding in findings:
                        if (
                            finding["package"] == dependency.get("name")
                            and finding["cve_id"] == cve_id
                        ):
                            finding["match_status"] = "matched"
                continue
            seen_cves.add(cve_id)
            findings.append(
                {
                    "package": dependency.get("name"),
                    "ecosystem": dependency.get("ecosystem"),
                    "source_file": dependency.get("source_file"),
                    "version": version,
                    "cve_id": cve_id,
                    "severity": entry.get("severity"),
                    "cwe_ids": list(entry.get("cwe_ids") or []),
                    "match_status": status,
                    "kev": bool(entry.get("kev", False)),
                }
            )
    findings.sort(
        key=lambda f: (f["match_status"] != "matched", f["package"] or "", f["cve_id"])
    )
    return findings


def build_vuln_report(
    dependencies: list[dict[str, Any]],
    affected_index: dict[str, list[dict[str, Any]]],
) -> dict[str, Any]:
    """Pure report builder over :func:`match_dependencies`."""
    findings = match_dependencies(dependencies, affected_index)
    return {
        "dependencies_checked": len(dependencies),
        "findings": findings,
        "matched_count": sum(
            1 for f in findings if f["match_status"] == "matched"
        ),
        "unknown_count": sum(
            1 for f in findings if f["match_status"] == "unknown"
        ),
        "kev_count": sum(1 for f in findings if f["kev"]),
    }


# ---------------------------------------------------------------------------
# DB-backed path (injectable client protocol, like code_queries)
# ---------------------------------------------------------------------------


@runtime_checkable
class VulnGraphClient(Protocol):
    """Injectable graph-client interface for vuln queries."""

    def affected_index(
        self, tenant_id: str, package_names: list[str]
    ) -> dict[str, list[dict[str, Any]]]:
        """Return the CVE/AFFECTS index for the given normalized names."""
        ...


class Neo4jVulnGraphClient:
    """Production :class:`VulnGraphClient` over ``Neo4jStorageClient``.

    All user input travels as query parameters; no values are
    interpolated into the Cypher text.
    """

    def __init__(self, neo4j_client: Any = None) -> None:
        if neo4j_client is None:
            from backend.config import get_config
            from backend.storage.neo4j_client import Neo4jStorageClient

            neo4j_client = Neo4jStorageClient.from_config(get_config())
        self._client = neo4j_client

    def affected_index(
        self, tenant_id: str, package_names: list[str]
    ) -> dict[str, list[dict[str, Any]]]:
        if not package_names:
            return {}
        query = """
        MATCH (cve:CVE)-[r:AFFECTS]->(pkg:Package)
        WHERE cve.tenant_id = $tenant_id
          AND pkg.tenant_id = $tenant_id
          AND pkg.name IN $package_names
        OPTIONAL MATCH (cve)-[:HAS_WEAKNESS]->(cwe:CWE)
        RETURN pkg.name AS package, cve.id AS cve_id,
               cve.severity AS severity, cve.kev AS kev,
               collect(DISTINCT cwe.id) AS cwe_ids,
               r.criteria AS criteria,
               r.criteria_version AS criteria_version,
               r.vulnerable AS vulnerable,
               r.version_start_including AS version_start_including,
               r.version_start_excluding AS version_start_excluding,
               r.version_end_including AS version_end_including,
               r.version_end_excluding AS version_end_excluding
        """
        rows = self._client.execute_read(
            query,
            {"tenant_id": tenant_id, "package_names": list(package_names)},
        )
        index: dict[str, list[dict[str, Any]]] = {}
        for row in rows:
            package = row.get("package")
            if not package:
                continue
            entry = dict(row)
            entry.pop("package", None)
            entry["cwe_ids"] = [c for c in (entry.get("cwe_ids") or []) if c]
            index.setdefault(package, []).append(entry)
        return index


def _default_client(client: VulnGraphClient | None) -> VulnGraphClient:
    return client if client is not None else Neo4jVulnGraphClient()


def vuln_report(
    dependencies: list[dict[str, Any]],
    tenant_id: str = "default",
    client: VulnGraphClient | None = None,
) -> dict[str, Any]:
    """DB-backed vuln report for already-extracted ``dependencies``."""
    graph_client = _default_client(client)
    names = sorted(
        {_normalize_package_name(d.get("name", "")) for d in dependencies} - {""}
    )
    affected_index = graph_client.affected_index(tenant_id, names)
    report = build_vuln_report(dependencies, affected_index)
    report["tenant_id"] = tenant_id
    return report


__all__ = [
    "Neo4jVulnGraphClient",
    "VulnGraphClient",
    "build_vuln_report",
    "match_dependencies",
    "vuln_report",
]
