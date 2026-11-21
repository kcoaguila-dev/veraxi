"""Vuln Intel query layer: join extracted dependencies against CVE data.

The join itself — :func:`match_dependencies` — is a pure function over
``(dependencies, affected_index)`` so it is testable without a
database. ``affected_index`` maps a normalized package name to a list
of affected entries, each a dict with the AFFECTS-edge shape written
by :mod:`backend.ingestion.vuln_intel`::

    {"cve_id", "severity", "kev", "cwe_ids", "criteria",
     "criteria_version", "vulnerable", "version_start_including",
     "version_start_excluding", "version_end_including",
     "version_end_excluding", "ecosystem", "introduced", "fixed"}

Affected entries may also be keyed by ``(ecosystem, name)``: an index
key of ``"pypi:requests"`` (ecosystem lowercased) matches only
dependencies of that ecosystem, while a bare ``"requests"`` key keeps
the original ecosystem-agnostic behaviour.

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
    introduced = entry.get("introduced")
    bounds = {
        "start_incl": entry.get("version_start_including")
        or (introduced if introduced and introduced != "0" else None),
        "start_excl": entry.get("version_start_excluding"),
        "end_incl": entry.get("version_end_including")
        or entry.get("last_affected"),
        "end_excl": entry.get("version_end_excluding") or entry.get("fixed"),
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


def _match_single_dependency(
    dependency: dict[str, Any],
    affected_index: dict[str, list[dict[str, Any]]],
) -> list[dict[str, Any]]:
    """Match one dependency record against ``affected_index``."""
    normalized = _normalize_package_name(dependency.get("name", ""))
    dep_ecosystem = str(dependency.get("ecosystem") or "").strip().lower()
    entries = list(affected_index.get(normalized) or [])
    if dep_ecosystem:
        entries = list(affected_index.get(f"{dep_ecosystem}:{normalized}") or []) + entries
    version = dependency.get("version")
    by_cve: dict[str, dict[str, Any]] = {}
    for entry in entries:
        cve_id = entry.get("cve_id")
        if not cve_id:
            continue
        entry_ecosystem = str(entry.get("ecosystem") or "").strip().lower()
        # An entry that declares a real ecosystem never matches a
        # dependency from a different ecosystem (same name, other
        # registry). Legacy CPE entries ("cpe" / unset) stay agnostic.
        if (
            entry_ecosystem
            and entry_ecosystem != "cpe"
            and dep_ecosystem
            and dep_ecosystem != "cpe"
            and entry_ecosystem != dep_ecosystem
            # OSV spells PyPI with capitals; both sides are lowered, and
            # the dependency extractor emits "pypi" for OSV "PyPI".
            and not (entry_ecosystem == "pypi" and dep_ecosystem == "pypi")
        ):
            continue
        status = _entry_match_status(version, entry)
        if status == "not_matched":
            continue
        # One finding per CVE per dependency: a confident match
        # wins over an unknown from another range of the same CVE.
        existing = by_cve.get(cve_id)
        if existing is not None:
            if status == "matched":
                existing["match_status"] = "matched"
            continue
        by_cve[cve_id] = {
            "package": dependency.get("name"),
            "ecosystem": dependency.get("ecosystem"),
            "source_file": dependency.get("source_file"),
            "version": version,
            "cve_id": cve_id,
            "advisory_id": entry.get("advisory_id") or cve_id,
            "severity": entry.get("severity"),
            "cwe_ids": list(entry.get("cwe_ids") or []),
            "match_status": status,
            "kev": bool(entry.get("kev", False)),
            "epss_score": entry.get("epss_score"),
            "epss_percentile": entry.get("epss_percentile"),
        }
    return list(by_cve.values())


def _finding_sort_key(finding: dict[str, Any]) -> tuple[Any, ...]:
    epss = finding.get("epss_score")
    epss_rank = -(float(epss) if epss is not None else -1.0)
    return (
        finding["match_status"] != "matched",
        not finding.get("kev", False),
        epss_rank,
        finding.get("package") or "",
        finding.get("cve_id") or "",
    )


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
        findings.extend(_match_single_dependency(dependency, affected_index))
    findings.sort(key=_finding_sort_key)
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
        WHERE cve.tenant_id IN [$tenant_id, 'public']
          AND pkg.tenant_id IN [$tenant_id, 'public']
          AND pkg.name IN $package_names
        OPTIONAL MATCH (cve)-[:HAS_WEAKNESS]->(cwe:CWE)
        RETURN pkg.name AS package, pkg.ecosystem AS package_ecosystem,
               cve.id AS cve_id,
               cve.severity AS severity, cve.kev AS kev,
               cve.epss_score AS epss_score,
               cve.epss_percentile AS epss_percentile,
               collect(DISTINCT cwe.id) AS cwe_ids,
               r.criteria AS criteria,
               r.criteria_version AS criteria_version,
               r.vulnerable AS vulnerable,
               r.ecosystem AS ecosystem,
               r.introduced AS introduced,
               r.fixed AS fixed,
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
            package_ecosystem = entry.pop("package_ecosystem", None)
            if not entry.get("ecosystem"):
                entry["ecosystem"] = package_ecosystem
            entry["cwe_ids"] = [c for c in (entry.get("cwe_ids") or []) if c]
            index.setdefault(package, []).append(entry)
            ecosystem_key = str(package_ecosystem or "").strip().lower()
            if ecosystem_key and ecosystem_key != "cpe":
                # Index keys use the lowercased ecosystem, which is the
                # extractor spelling ("pypi" for OSV "PyPI").
                index.setdefault(f"{ecosystem_key}:{package}", []).append(entry)
        return index


def _default_client(client: VulnGraphClient | None) -> VulnGraphClient:
    return client if client is not None else Neo4jVulnGraphClient()


def _package_import_candidates(package_name: str) -> list[str]:
    """Return candidate module names used in code imports for a package."""
    raw = (package_name or "").strip()
    if not raw:
        return []
    candidates = [raw]
    underscored = raw.replace("-", "_")
    if underscored not in candidates:
        candidates.append(underscored)
    return candidates


def attach_code_reachability(
    findings: list[dict[str, Any]],
    tenant_id: str = "default",
    max_depth: int = 3,
    code_client: Any = None,
    repo: str | None = None,
) -> list[dict[str, Any]]:
    """Enrich vulnerability findings with Repo X-Ray code-graph reachability.

    For each unique vulnerable package, queries ``code_queries.impact_analysis``
    for modules/functions that ``IMPORTS`` or ``CALLS`` the package (transitively)
    and attaches ``reachable_in_code`` and ``reachable_file_count`` to each
    finding. ``repo`` scopes reachability to one indexed repo; without
    it, hits from every repo are attached — each hit carries its
    ``repo_key``, and hits are deduplicated per (repo, symbol), so
    the same symbol reached in two repos counts for both.
    """
    if not findings:
        return findings

    from backend.retrieval.code_queries import impact_analysis

    cache: dict[str, list[dict[str, Any]]] = {}
    for finding in findings:
        pkg = finding.get("package") or ""
        if pkg not in cache:
            seen_hits: set[tuple[str, str]] = set()
            hits: list[dict[str, Any]] = []
            for candidate in _package_import_candidates(pkg):
                result = impact_analysis(
                    candidate,
                    tenant_id=tenant_id,
                    max_depth=max_depth,
                    client=code_client,
                    repo=repo,
                )
                for item in result.get("impacted") or []:
                    qn = item.get("qualified_name")
                    hit_key = (str(item.get("repo_key") or ""), str(qn or ""))
                    if qn and hit_key not in seen_hits:
                        seen_hits.add(hit_key)
                        hits.append(item)
            cache[pkg] = hits
        impacted = cache[pkg]
        finding["reachable_in_code"] = impacted[:20]
        finding["reachable_file_count"] = len(
            {item.get("path") for item in impacted if item.get("path")}
        )
    return findings


def vuln_report(
    dependencies: list[dict[str, Any]],
    tenant_id: str = "default",
    client: VulnGraphClient | None = None,
    include_reachability: bool = False,
    code_client: Any = None,
    max_depth: int = 3,
    repo: str | None = None,
) -> dict[str, Any]:
    """DB-backed vuln report for already-extracted ``dependencies``."""
    graph_client = _default_client(client)
    names = sorted(
        {_normalize_package_name(d.get("name", "")) for d in dependencies} - {""}
    )
    affected_index = graph_client.affected_index(tenant_id, names)
    report = build_vuln_report(dependencies, affected_index)
    if include_reachability:
        attach_code_reachability(
            report["findings"],
            tenant_id=tenant_id,
            max_depth=max_depth,
            code_client=code_client,
            repo=repo,
        )
    report["tenant_id"] = tenant_id
    return report


__all__ = [
    "Neo4jVulnGraphClient",
    "VulnGraphClient",
    "attach_code_reachability",
    "build_vuln_report",
    "match_dependencies",
    "vuln_report",
]
