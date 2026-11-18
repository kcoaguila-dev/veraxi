"""Tests for the Vuln Intel query layer and MCP tool.

The pure join runs over hand-built dependency / affected-index data —
no database. The Neo4j adapter is exercised with a recording stub to
prove its Cypher stays parameterized, and registration is checked the
same way as Phase 3's code tools.
"""

import asyncio

from backend.retrieval.vuln_queries import (
    Neo4jVulnGraphClient,
    build_vuln_report,
    match_dependencies,
    vuln_report,
)

AFFECTED_INDEX = {
    "widgetlib": [
        {
            "cve_id": "CVE-2024-1111",
            "severity": "HIGH",
            "kev": True,
            "cwe_ids": ["CWE-79"],
            "criteria": "cpe:2.3:a:acme:widgetlib:*:*:*:*:*:*:*:*",
            "criteria_version": "*",
            "vulnerable": True,
            "version_start_including": "1.0",
            "version_start_excluding": None,
            "version_end_including": None,
            "version_end_excluding": "2.0",
        },
        {
            "cve_id": "CVE-2024-2222",
            "severity": "CRITICAL",
            "kev": False,
            "cwe_ids": ["CWE-89"],
            "criteria": "cpe:2.3:a:acme:widgetlib:3.1:*:*:*:*:*:*:*",
            "criteria_version": "3.1",
            "vulnerable": True,
            "version_start_including": None,
            "version_start_excluding": None,
            "version_end_including": None,
            "version_end_excluding": None,
        },
    ],
    "otherpkg": [
        {
            "cve_id": "CVE-2024-3333",
            "severity": "MEDIUM",
            "kev": False,
            "cwe_ids": ["CWE-20"],
            "criteria": "cpe:2.3:a:acme:otherpkg:*:*:*:*:*:*:*:*",
            "criteria_version": "*",
            "vulnerable": True,
            "version_start_including": None,
            "version_start_excluding": None,
            "version_end_including": None,
            "version_end_excluding": None,
        }
    ],
}


def _dep(name, version, ecosystem="pypi"):
    return {
        "name": name,
        "version": version,
        "version_spec": version or "",
        "spec_kind": "exact" if version else "unknown",
        "ecosystem": ecosystem,
        "source_file": "pyproject.toml",
    }


def test_join_matched_inside_range():
    findings = match_dependencies([_dep("widgetlib", "1.5.0")], AFFECTED_INDEX)
    assert len(findings) == 1
    finding = findings[0]
    assert finding["package"] == "widgetlib"
    assert finding["version"] == "1.5.0"
    assert finding["cve_id"] == "CVE-2024-1111"
    assert finding["severity"] == "HIGH"
    assert finding["cwe_ids"] == ["CWE-79"]
    assert finding["match_status"] == "matched"
    assert finding["kev"] is True


def test_join_outside_range_not_matched():
    findings = match_dependencies([_dep("widgetlib", "2.5.0")], AFFECTED_INDEX)
    assert findings == []


def test_join_exact_criteria_version():
    findings = match_dependencies([_dep("widgetlib", "3.1")], AFFECTED_INDEX)
    assert [f["cve_id"] for f in findings] == ["CVE-2024-2222"]
    assert findings[0]["match_status"] == "matched"


def test_join_unparseable_version_is_unknown_never_matched():
    findings = match_dependencies([_dep("widgetlib", "1.5.0rc1")], AFFECTED_INDEX)
    assert findings
    assert all(f["match_status"] == "unknown" for f in findings)
    # Missing version is likewise unknown for every CVE of the package,
    # plus the range-less otherpkg CVE when that package is present.
    findings = match_dependencies([_dep("widgetlib", None)], AFFECTED_INDEX)
    assert {f["cve_id"] for f in findings} == {"CVE-2024-1111", "CVE-2024-2222"}
    assert all(f["match_status"] == "unknown" for f in findings)


def test_join_rangeless_cve_is_unknown():
    findings = match_dependencies([_dep("otherpkg", "9.9.9")], AFFECTED_INDEX)
    assert len(findings) == 1
    assert findings[0]["match_status"] == "unknown"


def test_join_name_normalization():
    # CPE-style underscores / case differences still join to the dep.
    findings = match_dependencies([_dep("WidgetLib", "1.0")], AFFECTED_INDEX)
    assert findings and findings[0]["match_status"] == "matched"


def test_join_no_cve_no_finding():
    assert match_dependencies([_dep("cleanpkg", "1.0")], AFFECTED_INDEX) == []


def test_build_vuln_report_counts():
    report = build_vuln_report(
        [_dep("widgetlib", "1.5.0"), _dep("otherpkg", "1.0"), _dep("clean", "1.0")],
        AFFECTED_INDEX,
    )
    assert report["dependencies_checked"] == 3
    assert report["matched_count"] == 1
    assert report["unknown_count"] == 1
    assert report["kev_count"] == 1


# ---------------------------------------------------------------------------
# DB-backed path with a fake client + MCP tool + registration
# ---------------------------------------------------------------------------


class FakeVulnGraphClient:
    def __init__(self, index):
        self.index = index
        self.calls = []

    def affected_index(self, tenant_id, package_names):
        self.calls.append((tenant_id, list(package_names)))
        return {k: v for k, v in self.index.items() if k in package_names}


def test_vuln_report_with_fake_client():
    fake = FakeVulnGraphClient(AFFECTED_INDEX)
    report = vuln_report([_dep("widgetlib", "1.5.0")], tenant_id="t", client=fake)
    assert report["tenant_id"] == "t"
    assert report["matched_count"] == 1
    assert fake.calls == [("t", ["widgetlib"])]


def test_mcp_tool_with_fake_client_and_repo_path(tmp_path):
    from backend.mcp_server.tools.vuln_tools import tool_schemas, vuln_report as tool

    assert {d["function"]["name"] for d in tool_schemas()} == {"vuln_report"}
    fake = FakeVulnGraphClient(AFFECTED_INDEX)
    result = tool(
        tenant_id="t", dependencies=[_dep("widgetlib", "1.5.0")], client=fake
    )
    assert result["findings"][0]["cve_id"] == "CVE-2024-1111"

    (tmp_path / "pyproject.toml").write_text(
        '[project]\ndependencies = ["widgetlib==1.5.0"]\n', encoding="utf-8"
    )
    fake2 = FakeVulnGraphClient(AFFECTED_INDEX)
    result = tool(tenant_id="t", repo_path=str(tmp_path), client=fake2)
    assert result["dependencies_checked"] == 1
    assert result["matched_count"] == 1


def test_tool_registered_in_dispatch_and_mcp_server():
    from backend.mcp_server.handlers.tool_registry import TOOL_HANDLERS
    from backend.mcp_server.handlers.tool_schemas import REGISTERED_TOOLS
    from backend.mcp_server.tool_dispatch import get_tools

    assert "mcp_vuln_report" in {tool.name for tool in REGISTERED_TOOLS}
    assert "mcp_vuln_report" in TOOL_HANDLERS

    tools = asyncio.run(get_tools({"file_search_enabled": True}, tenant_id="t"))
    assert "vuln_report" in {t["function"]["name"] for t in tools}


def test_dispatch_execute_single_tool(monkeypatch):
    import backend.mcp_server.tools.vuln_tools as vuln_tools_module
    from backend.mcp_server.tool_dispatch import _execute_single_tool

    fake = FakeVulnGraphClient(AFFECTED_INDEX)
    original = vuln_tools_module.vuln_report
    monkeypatch.setattr(
        vuln_tools_module,
        "vuln_report",
        lambda tenant_id="default", dependencies=None, repo_path=None, client=None: original(
            tenant_id=tenant_id, dependencies=dependencies, repo_path=repo_path, client=fake
        ),
    )
    hits, graph_hits = _execute_single_tool(
        "vuln_report",
        {"dependencies": [_dep("widgetlib", "1.5.0")]},
        "t",
        {"file_search_enabled": True},
    )
    assert graph_hits == []
    assert hits[0].payload["matched_count"] == 1
    assert hits[0].sources == ["Vuln Intel"]

    hits, graph_hits = _execute_single_tool(
        "vuln_report", {"dependencies": []}, "t", {"file_search_enabled": False}
    )
    assert hits == [] and graph_hits == []


# ---------------------------------------------------------------------------
# Neo4j adapter: parameterized Cypher only
# ---------------------------------------------------------------------------


class RecordingNeo4jStub:
    def __init__(self):
        self.calls = []

    def execute_read(self, query, parameters=None):
        self.calls.append((query, parameters or {}))
        return [
            {
                "package": "widgetlib",
                "cve_id": "CVE-2024-1111",
                "severity": "HIGH",
                "kev": True,
                "cwe_ids": ["CWE-79"],
                "criteria": "cpe:2.3:a:acme:widgetlib:*:*:*:*:*:*:*:*",
                "criteria_version": "*",
                "vulnerable": True,
                "version_start_including": "1.0",
                "version_start_excluding": None,
                "version_end_including": None,
                "version_end_excluding": "2.0",
            }
        ]


def test_neo4j_adapter_parameterized():
    stub = RecordingNeo4jStub()
    client = Neo4jVulnGraphClient(stub)
    index = client.affected_index("tenant-a", ["widgetlib"])
    assert index["widgetlib"][0]["cve_id"] == "CVE-2024-1111"
    assert len(stub.calls) == 1
    query, params = stub.calls[0]
    assert "tenant-a" not in query
    assert "widgetlib" not in query
    assert params == {"tenant_id": "tenant-a", "package_names": ["widgetlib"]}
    assert client.affected_index("tenant-a", []) == {}


# ---------------------------------------------------------------------------
# OSV ecosystem-keyed matching (introduced/fixed bounds)
# ---------------------------------------------------------------------------

OSV_INDEX = {
    "pypi:requests": [
        {
            "cve_id": "GHSA-j8r2-6x86-q33q",
            "severity": "MODERATE",
            "kev": True,
            "cwe_ids": ["CWE-212"],
            "criteria": "osv:PyPI:requests:0-2.31.2",
            "criteria_version": "",
            "vulnerable": True,
            "ecosystem": "PyPI",
            "introduced": "0",
            "fixed": "2.31.2",
            "version_start_including": None,
            "version_start_excluding": None,
            "version_end_including": None,
            "version_end_excluding": None,
        }
    ],
    "pypi:urllib3": [
        {
            "cve_id": "CVE-2021-33503",
            "severity": "HIGH",
            "kev": False,
            "cwe_ids": ["CWE-1333"],
            "criteria": "osv:PyPI:urllib3:0-1.26.5",
            "criteria_version": "",
            "vulnerable": True,
            "ecosystem": "PyPI",
            "introduced": "0",
            "fixed": "1.26.5",
            "version_start_including": None,
            "version_start_excluding": None,
            "version_end_including": None,
            "version_end_excluding": None,
        }
    ],
    "maven:log4j-core": [
        {
            "cve_id": "CVE-2021-44228",
            "severity": "CRITICAL",
            "kev": True,
            "cwe_ids": ["CWE-917"],
            "criteria": "osv:Maven:log4j-core:2.0.0-2.15.0",
            "criteria_version": "",
            "vulnerable": True,
            "ecosystem": "Maven",
            "introduced": "2.0.0",
            "fixed": "2.15.0",
            "version_start_including": None,
            "version_start_excluding": None,
            "version_end_including": None,
            "version_end_excluding": None,
        }
    ],
}


def test_osv_index_matches_requests_urllib3_log4j():
    deps = [
        _dep("requests", "2.31.0"),
        _dep("urllib3", "1.26.4"),
        _dep("log4j-core", "2.14.1", ecosystem="maven"),
    ]
    report = build_vuln_report(deps, OSV_INDEX)
    assert report["matched_count"] == 3
    kev_ids = {f["cve_id"] for f in report["findings"] if f["kev"]}
    assert kev_ids == {"GHSA-j8r2-6x86-q33q", "CVE-2021-44228"}


def test_osv_ecosystem_mismatch_never_matches():
    # Same package name, wrong ecosystem: the PyPI requests advisory
    # must not fire for an npm dependency also named requests.
    findings = match_dependencies(
        [_dep("requests", "2.31.0", ecosystem="npm")], OSV_INDEX
    )
    assert findings == []
    # Fixed versions do not match.
    assert match_dependencies([_dep("requests", "2.32.0")], OSV_INDEX) == []
    assert match_dependencies([_dep("log4j-core", "2.17.0", ecosystem="maven")], OSV_INDEX) == []
