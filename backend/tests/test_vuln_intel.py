"""Tests for Vuln Intel ingestion: NVD/KEV parsers, version matching,
dependency extraction, the Neo4j writer and the httpx fetch layer.

All pure / fake-based: no network (fetch tests use an httpx
MockTransport), no database (writer tests use a recording client).
"""

import httpx
import pytest

from backend.ingestion.dependencies import (
    extract_dependencies_from_repo,
    parse_package_json_text,
    parse_pubspec_text,
    parse_pyproject_text,
    parse_version_spec,
)
from backend.ingestion.vuln_intel import (
    KEV_JSON_URL,
    NVD_API_URL,
    VersionRange,
    apply_kev,
    compare_versions,
    fetch_kev_records,
    fetch_nvd_records,
    parse_kev_csv,
    parse_kev_payload,
    parse_nvd_payload,
    parse_version,
    version_in_range,
    write_vuln_records,
)

NVD_PAYLOAD = {
    "vulnerabilities": [
        {
            "cve": {
                "id": "CVE-2024-1111",
                "published": "2024-01-10T00:00:00.000",
                "lastModified": "2024-02-01T00:00:00.000",
                "descriptions": [
                    {"lang": "es", "value": "descripcion"},
                    {"lang": "en", "value": "Widgetlib XSS flaw."},
                ],
                "weaknesses": [
                    {
                        "description": [
                            {"lang": "en", "value": "CWE-79"},
                            {"lang": "en", "value": "CWE-79"},
                        ]
                    }
                ],
                "metrics": {
                    "cvssMetricV31": [
                        {
                            "type": "Primary",
                            "cvssData": {"baseScore": 7.5, "baseSeverity": "HIGH"},
                        }
                    ]
                },
                "configurations": [
                    {
                        "nodes": [
                            {
                                "operator": "OR",
                                "cpeMatch": [
                                    {
                                        "vulnerable": True,
                                        "criteria": "cpe:2.3:a:acme:widgetlib:*:*:*:*:*:*:*:*",
                                        "versionStartIncluding": "1.0",
                                        "versionEndExcluding": "2.0",
                                    }
                                ],
                            }
                        ]
                    }
                ],
            }
        },
        {
            "cve": {
                "id": "CVE-2024-2222",
                "published": "2024-03-01T00:00:00.000",
                "lastModified": "2024-03-02T00:00:00.000",
                "descriptions": [{"lang": "en", "value": "Widgetlib SQLi in 3.1."}],
                "weaknesses": [
                    {"description": [{"lang": "en", "value": "CWE-89"}]}
                ],
                "metrics": {
                    "cvssMetricV2": [
                        {
                            "type": "Primary",
                            "cvssData": {"baseScore": 9.8, "baseSeverity": "CRITICAL"},
                        }
                    ]
                },
                "configurations": [
                    {
                        "nodes": [
                            {
                                "operator": "OR",
                                "cpeMatch": [
                                    {
                                        "vulnerable": True,
                                        "criteria": "cpe:2.3:a:acme:widgetlib:3.1:*:*:*:*:*:*:*",
                                    }
                                ],
                            }
                        ]
                    }
                ],
            }
        },
        {
            "cve": {
                "id": "CVE-2024-3333",
                "descriptions": [{"lang": "en", "value": "Other issue, no CPE."}],
                "weaknesses": [
                    {"description": [{"lang": "en", "value": "CWE-20"}]}
                ],
            }
        },
    ]
}

KEV_PAYLOAD = {
    "vulnerabilities": [
        {
            "cveID": "CVE-2024-1111",
            "vendorProject": "Acme",
            "product": "Widgetlib",
            "vulnerabilityName": "Acme Widgetlib XSS",
            "dateAdded": "2024-01-15",
            "knownRansomwareCampaignUse": "Known",
            "shortDescription": "Widgetlib XSS.",
        },
        {
            "cveID": "CVE-2020-9999",
            "vendorProject": "Other",
            "product": "Thing",
            "vulnerabilityName": "Other Thing RCE",
            "dateAdded": "2023-05-01",
            "knownRansomwareCampaignUse": "Unknown",
            "shortDescription": "Thing RCE.",
        },
    ]
}

KEV_CSV = (
    "cveID,vendorProject,product,vulnerabilityName,dateAdded,"
    "shortDescription,requiredAction,dueDate,knownRansomwareCampaignUse,notes\n"
    "CVE-2024-1111,Acme,Widgetlib,Acme Widgetlib XSS,2024-01-15,"
    "Widgetlib XSS.,Apply updates,2024-02-05,Known,\n"
)


# ---------------------------------------------------------------------------
# NVD / KEV parsing
# ---------------------------------------------------------------------------


def test_parse_nvd_payload():
    records = parse_nvd_payload(NVD_PAYLOAD)
    assert [r.id for r in records] == [
        "CVE-2024-1111",
        "CVE-2024-2222",
        "CVE-2024-3333",
    ]
    first = records[0]
    assert first.description == "Widgetlib XSS flaw."
    assert first.severity == "HIGH"
    assert first.cvss_score == 7.5
    assert first.published == "2024-01-10T00:00:00.000"
    assert first.cwe_ids == ["CWE-79"]
    assert len(first.affected) == 1
    affected = first.affected[0]
    assert affected.vendor == "acme"
    assert affected.product == "widgetlib"
    assert affected.version_start_including == "1.0"
    assert affected.version_end_excluding == "2.0"

    second = records[1]
    assert second.severity == "CRITICAL"
    assert second.cwe_ids == ["CWE-89"]
    assert second.affected[0].criteria_version == "3.1"

    third = records[2]
    assert third.affected == []
    assert third.severity is None


def test_parse_kev_payload_and_csv_agree():
    from_json = parse_kev_payload(KEV_PAYLOAD)
    assert [r["cve_id"] for r in from_json] == ["CVE-2024-1111", "CVE-2020-9999"]
    assert from_json[0]["date_added"] == "2024-01-15"
    assert from_json[0]["known_ransomware_campaign_use"] == "Known"

    from_csv = parse_kev_csv(KEV_CSV)
    assert len(from_csv) == 1
    assert from_csv[0]["cve_id"] == "CVE-2024-1111"
    assert from_csv[0]["product"] == "Widgetlib"
    assert from_csv[0]["date_added"] == "2024-01-15"
    assert from_csv[0]["known_ransomware_campaign_use"] == "Known"


def test_apply_kev_marks_records():
    records = parse_nvd_payload(NVD_PAYLOAD)
    apply_kev(records, parse_kev_payload(KEV_PAYLOAD))
    assert records[0].kev is True
    assert records[0].kev_date == "2024-01-15"
    assert records[1].kev is False


# ---------------------------------------------------------------------------
# Version comparison (fail closed)
# ---------------------------------------------------------------------------


def test_parse_and_compare_versions():
    assert parse_version("1.2.3") == (1, 2, 3)
    assert parse_version("v2.0") == (2, 0)
    assert parse_version("1.2.3-beta") is None
    assert parse_version("*") is None
    assert parse_version(None) is None
    assert compare_versions("1.10", "1.9") == 1
    assert compare_versions("1.0", "1.0.0") == 0
    assert compare_versions("1.0", "x") is None


def test_version_in_range_bounds():
    rng = VersionRange(
        product="widgetlib",
        version_start_including="1.0",
        version_end_excluding="2.0",
    )
    assert version_in_range("1.0", rng) == "matched"
    assert version_in_range("1.5.2", rng) == "matched"
    assert version_in_range("2.0", rng) == "not_matched"
    assert version_in_range("0.9", rng) == "not_matched"


def test_version_in_range_exact_criteria_version():
    rng = VersionRange(product="widgetlib", criteria_version="3.1")
    assert version_in_range("3.1", rng) == "matched"
    assert version_in_range("3.2", rng) == "not_matched"


def test_version_in_range_fail_closed():
    rng = VersionRange(
        product="widgetlib",
        version_start_including="1.0",
        version_end_excluding="2.0",
    )
    # Unparseable installed version -> unknown, never matched.
    assert version_in_range("1.5.0rc1", rng) == "unknown"
    assert version_in_range(None, rng) == "unknown"
    # Unparseable bound -> unknown.
    bad = VersionRange(product="x", version_end_excluding="2.x")
    assert version_in_range("1.0", bad) == "unknown"
    # No bounds and no concrete criteria version -> unknown.
    empty = VersionRange(product="x", criteria_version="*")
    assert version_in_range("1.0", empty) == "unknown"
    # Not-vulnerable CPE entries never match.
    safe = VersionRange(product="x", vulnerable=False, criteria_version="1.0")
    assert version_in_range("1.0", safe) == "not_matched"


# ---------------------------------------------------------------------------
# Dependency extraction
# ---------------------------------------------------------------------------

PYPROJECT = """
[project]
dependencies = [
    "widgetlib==1.5.0",
    "requests>=2.28.0",
    "flask~=2.0",
    "mystery-pkg",
    "direct @ https://example.com/direct-1.0.tar.gz",
]

[tool.poetry.dependencies]
poetry-dep = "^3.2.1"
"""

PACKAGE_JSON = """
{"dependencies": {"widgetlib-js": "^1.2.3", "left-pad": "1.3.0"},
 "devDependencies": {"jest": "~29.0.0", "star": "*"}}
"""

PUBSPEC = """
name: sample
dependencies:
  flutter:
    sdk: flutter
  http: ^0.13.5
  provider: 6.0.5
dev_dependencies:
  flutter_test:
    sdk: flutter
"""


def test_parse_version_spec_kinds():
    assert parse_version_spec("==1.2.3") == ("1.2.3", "exact")
    assert parse_version_spec("1.2.3") == ("1.2.3", "exact")
    assert parse_version_spec("^1.2.3") == ("1.2.3", "caret")
    assert parse_version_spec("~1.2") == ("1.2", "tilde")
    assert parse_version_spec(">=2.0,<3") == ("2.0", "range")
    assert parse_version_spec("*") == (None, "unknown")
    assert parse_version_spec("") == (None, "unknown")


def test_parse_pyproject_exact_and_ranged():
    records = parse_pyproject_text(PYPROJECT)
    by_name = {r["name"]: r for r in records}
    assert by_name["widgetlib"]["version"] == "1.5.0"
    assert by_name["widgetlib"]["spec_kind"] == "exact"
    assert by_name["requests"]["version"] == "2.28.0"
    assert by_name["requests"]["spec_kind"] == "range"
    assert by_name["flask"]["version"] == "2.0"
    assert by_name["mystery-pkg"]["version"] is None
    assert by_name["direct"]["version"] is None
    assert by_name["poetry-dep"]["version"] == "3.2.1"
    assert by_name["poetry-dep"]["spec_kind"] == "caret"
    assert all(r["ecosystem"] == "pypi" for r in records)


def test_parse_package_json():
    records = parse_package_json_text(PACKAGE_JSON)
    by_name = {r["name"]: r for r in records}
    assert by_name["widgetlib-js"]["version"] == "1.2.3"
    assert by_name["widgetlib-js"]["spec_kind"] == "caret"
    assert by_name["left-pad"]["version"] == "1.3.0"
    assert by_name["jest"]["spec_kind"] == "tilde"
    assert by_name["star"]["version"] is None
    assert all(r["ecosystem"] == "npm" for r in records)


def test_parse_pubspec():
    records = parse_pubspec_text(PUBSPEC)
    by_name = {r["name"]: r for r in records}
    assert by_name["http"]["version"] == "0.13.5"
    assert by_name["http"]["spec_kind"] == "caret"
    assert by_name["provider"]["version"] == "6.0.5"
    # SDK deps carry no version (fail closed).
    assert by_name["flutter"]["version"] is None
    assert by_name["flutter_test"]["version"] is None
    assert all(r["ecosystem"] == "pub" for r in records)


def test_extract_dependencies_from_repo(tmp_path):
    (tmp_path / "pyproject.toml").write_text(PYPROJECT, encoding="utf-8")
    sub = tmp_path / "web"
    sub.mkdir()
    (sub / "package.json").write_text(PACKAGE_JSON, encoding="utf-8")
    skipped = tmp_path / "node_modules" / "x"
    skipped.mkdir(parents=True)
    (skipped / "package.json").write_text(PACKAGE_JSON, encoding="utf-8")

    records = extract_dependencies_from_repo(tmp_path)
    sources = {r["source_file"] for r in records}
    assert sources == {"pyproject.toml", "web/package.json"}


def test_extract_dependencies_skips_symlinked_manifest_escaping_root(tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "pyproject.toml").write_text(PYPROJECT, encoding="utf-8")
    repo = tmp_path / "repo"
    repo.mkdir()
    (repo / "pyproject.toml").symlink_to(outside / "pyproject.toml")

    assert extract_dependencies_from_repo(repo) == []


# ---------------------------------------------------------------------------
# Writer (recording fake client)
# ---------------------------------------------------------------------------


class RecordingWriteClient:
    """Records execute_write calls instead of touching a database."""

    def __init__(self):
        self.calls: list[tuple[str, dict]] = []

    def execute_write(self, query, parameters=None):
        self.calls.append((query, parameters or {}))
        return []

    def execute_read(self, query, parameters=None):  # pragma: no cover
        raise AssertionError("writer must not read")


def test_writer_parameterized_and_tenant_scoped():
    records = parse_nvd_payload(NVD_PAYLOAD)
    client = RecordingWriteClient()
    result = write_vuln_records(
        client, records, tenant_id="tenant-a", kev_records=parse_kev_payload(KEV_PAYLOAD)
    )
    assert result == {
        "cves_written": 3,
        "cwe_links_written": 3,
        "affects_links_written": 2,
    }
    assert client.calls
    for query, params in client.calls:
        assert "tenant-a" not in query
        assert "CVE-2024-1111" not in query
        assert "$" in query
        assert "tenant-a" in str(params)

    cve_writes = [p for q, p in client.calls if "MERGE (n:CVE" in q]
    first = [p for p in cve_writes if p["properties"]["id"] == "CVE-2024-1111"]
    assert first and first[0]["properties"]["kev"] is True
    assert first[0]["properties"]["kev_date"] == "2024-01-15"
    assert first[0]["properties"]["tenant_id"] == "tenant-a"

    affects = [p for q, p in client.calls if "AFFECTS" in q]
    assert affects and affects[0]["properties"]["version_end_excluding"] == "2.0"
    weakness = [q for q, _ in client.calls if "HAS_WEAKNESS" in q]
    assert len(weakness) == 3


# ---------------------------------------------------------------------------
# Fetch layer (mocked httpx transport, no network)
# ---------------------------------------------------------------------------


def _mock_client(handler) -> httpx.Client:
    return httpx.Client(transport=httpx.MockTransport(handler))


def test_fetch_nvd_records_with_mock_transport(monkeypatch):
    monkeypatch.delenv("NVD_API_KEY", raising=False)
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["url"] = str(request.url)
        seen["api_key_header"] = request.headers.get("apiKey")
        return httpx.Response(200, json=NVD_PAYLOAD)

    records = fetch_nvd_records(client=_mock_client(handler), api_key="test-key")
    assert [r.id for r in records] == ["CVE-2024-1111", "CVE-2024-2222", "CVE-2024-3333"]
    assert seen["url"].startswith(NVD_API_URL)
    assert seen["api_key_header"] == "test-key"


def test_fetch_nvd_records_key_from_env(monkeypatch):
    monkeypatch.setenv("NVD_API_KEY", "env-key")
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["api_key_header"] = request.headers.get("apiKey")
        return httpx.Response(200, json={"vulnerabilities": []})

    assert fetch_nvd_records(client=_mock_client(handler)) == []
    assert seen["api_key_header"] == "env-key"


def test_fetch_kev_records_with_mock_transport():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["url"] = str(request.url)
        return httpx.Response(200, json=KEV_PAYLOAD)

    records = fetch_kev_records(client=_mock_client(handler))
    assert seen["url"] == KEV_JSON_URL
    assert records[0]["cve_id"] == "CVE-2024-1111"


def test_fetch_propagates_http_errors():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500)

    with pytest.raises(httpx.HTTPStatusError):
        fetch_kev_records(client=_mock_client(handler))


def test_writer_batch_reduces_round_trips_and_is_parameterized():
    from backend.ingestion.vuln_intel import write_vuln_records_batch

    records = parse_nvd_payload(NVD_PAYLOAD)
    client = RecordingWriteClient()
    result = write_vuln_records_batch(
        client, records, tenant_id="tenant-b", kev_records=parse_kev_payload(KEV_PAYLOAD)
    )
    assert result == {
        "cves_written": 3,
        "cwe_links_written": 3,
        "affects_links_written": 2,
    }
    assert len(client.calls) == 5
    for query, params in client.calls:
        assert "UNWIND $rows AS row" in query
        assert "tenant-b" not in query
        assert "CVE-2024-1111" not in query
        assert "tenant-b" in str(params)


def test_fetch_nvd_records_includes_bounded_default_params(monkeypatch):
    monkeypatch.delenv("NVD_API_KEY", raising=False)
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["params"] = dict(request.url.params)
        return httpx.Response(200, json={"vulnerabilities": []})

    assert fetch_nvd_records(client=_mock_client(handler)) == []
    assert seen["params"]["resultsPerPage"] == "100"
    assert "lastModStartDate" in seen["params"]
    assert "lastModEndDate" in seen["params"]


# ---------------------------------------------------------------------------
# OSV.dev batch lookup (mocked httpx transport, no network)
# ---------------------------------------------------------------------------

OSV_ADVISORIES = {
    "GHSA-j8r2-6x86-q33q": {
        "id": "GHSA-j8r2-6x86-q33q",
        "aliases": ["CVE-2023-32681"],
        "summary": "Requests redirects leak Proxy-Authorization headers.",
        "database_specific": {"severity": "MODERATE", "cwe_ids": ["CWE-212"]},
        "affected": [
            {
                "package": {"name": "requests", "ecosystem": "PyPI"},
                "ranges": [
                    {"type": "ECOSYSTEM", "events": [{"introduced": "0"}, {"fixed": "2.31.2"}]}
                ],
            }
        ],
    },
    "CVE-2021-33503": {
        "id": "CVE-2021-33503",
        "aliases": ["GHSA-5r5r-9r8c-9r5r"],
        "summary": "urllib3 catastrophic backtracking.",
        "database_specific": {"severity": "HIGH", "cwe_ids": ["CWE-1333"]},
        "affected": [
            {
                "package": {"name": "urllib3", "ecosystem": "PyPI"},
                "ranges": [
                    {"type": "ECOSYSTEM", "events": [{"introduced": "0"}, {"fixed": "1.26.5"}]}
                ],
            }
        ],
    },
    "CVE-2021-44228": {
        "id": "CVE-2021-44228",
        "aliases": ["GHSA-jfh8-c2jp-5v3q"],
        "summary": "Log4Shell RCE.",
        "database_specific": {"severity": "CRITICAL", "cwe_ids": ["CWE-917"]},
        "affected": [
            {
                "package": {
                    "name": "org.apache.logging.log4j:log4j-core",
                    "ecosystem": "Maven",
                },
                "ranges": [
                    {
                        "type": "SEMVER",
                        "events": [{"introduced": "2.0.0"}, {"fixed": "2.15.0"}],
                    }
                ],
            }
        ],
    },
}

OSV_BATCH_IDS = {
    "requests": ["GHSA-j8r2-6x86-q33q"],
    "urllib3": ["CVE-2021-33503"],
    "org.apache.logging.log4j:log4j-core": ["CVE-2021-44228"],
    "log4j-core": ["CVE-2021-44228"],
}


def _osv_handler(request: httpx.Request) -> httpx.Response:
    if request.url.path.endswith("/querybatch"):
        import json as _json

        body = _json.loads(request.content)
        results = []
        for query in body["queries"]:
            ids = OSV_BATCH_IDS.get(query["package"]["name"], [])
            results.append({"vulns": [{"id": i} for i in ids]})
        return httpx.Response(200, json={"results": results})
    vuln_id = request.url.path.rsplit("/", 1)[-1]
    return httpx.Response(200, json=OSV_ADVISORIES[vuln_id])


def test_osv_ecosystem_mapping():
    from backend.ingestion.vuln_intel import osv_ecosystem

    assert osv_ecosystem("pypi") == "PyPI"
    assert osv_ecosystem("npm") == "npm"
    assert osv_ecosystem("maven") == "Maven"
    assert osv_ecosystem("pub") == "Pub"
    assert osv_ecosystem("go") == "Go"
    assert osv_ecosystem("cargo") == "crates.io"
    assert osv_ecosystem("PyPI") == "PyPI"
    assert osv_ecosystem("bogus") is None
    assert osv_ecosystem(None) is None


def test_fetch_osv_for_packages_matches_known_vulnerable_versions():
    from backend.ingestion.vuln_intel import fetch_osv_for_packages

    packages = [
        {"name": "requests", "version": "2.31.0", "ecosystem": "pypi"},
        {"name": "urllib3", "version": "1.26.4", "ecosystem": "pypi"},
        {"name": "log4j-core", "version": "2.14.1", "ecosystem": "maven"},
    ]
    records = fetch_osv_for_packages(packages, client=_mock_client(_osv_handler))
    by_id = {r.id: r for r in records}
    assert set(by_id) == {"GHSA-j8r2-6x86-q33q", "CVE-2021-33503", "CVE-2021-44228"}
    ghsa = by_id["GHSA-j8r2-6x86-q33q"]
    assert ghsa.aliases == ["CVE-2023-32681"]
    assert ghsa.affected[0].ecosystem == "PyPI"
    assert ghsa.affected[0].fixed == "2.31.2"
    assert version_in_range("2.31.0", ghsa.affected[0]) == "matched"
    assert version_in_range("1.26.4", by_id["CVE-2021-33503"].affected[0]) == "matched"
    log4j = by_id["CVE-2021-44228"]
    assert version_in_range("2.14.1", log4j.affected[0]) == "matched"
    assert version_in_range("2.17.0", log4j.affected[0]) == "not_matched"


def test_osv_kev_enrichment_matches_cve_alias_of_ghsa():
    from backend.ingestion.vuln_intel import fetch_osv_for_packages

    packages = [{"name": "requests", "version": "2.31.0", "ecosystem": "pypi"}]
    records = fetch_osv_for_packages(packages, client=_mock_client(_osv_handler))
    apply_kev(records, [{"cve_id": "CVE-2023-32681", "date_added": "2023-06-01"}])
    assert records[0].kev is True
    assert records[0].kev_date == "2023-06-01"


def test_osv_writer_keys_packages_by_ecosystem_and_name():
    from backend.ingestion.vuln_intel import fetch_osv_for_packages, write_vuln_records_batch

    packages = [
        {"name": "requests", "version": "2.31.0", "ecosystem": "pypi"},
        {"name": "log4j-core", "version": "2.14.1", "ecosystem": "maven"},
    ]
    records = fetch_osv_for_packages(packages, client=_mock_client(_osv_handler))
    client = RecordingWriteClient()
    write_vuln_records_batch(client, records, tenant_id="tenant-a")
    pkg_params = [p for q, p in client.calls if "MERGE (n:Package" in q]
    assert pkg_params
    keys = {row["vuln_key"] for row in pkg_params[0]["rows"]}
    assert any("PyPI:requests" in k for k in keys)
    assert any("Maven:" in k and "log4j-core" in k for k in keys)
    affects = [p for q, p in client.calls if "AFFECTS" in q]
    props = affects[0]["rows"][0]["properties"]
    assert props["ecosystem"] in ("PyPI", "Maven")
    assert "introduced" in props and "fixed" in props


def test_parse_and_apply_epss_matches_alias():
    from backend.ingestion.vuln_intel import (
        CVERecord,
        apply_epss,
        parse_epss_payload,
    )

    payload = {
        "status": "OK",
        "data": [
            {"cve": "CVE-2023-32681", "epss": "0.42", "percentile": "0.97"},
            {"cve": "CVE-2024-9999", "epss": "bad", "percentile": "0.5"},
        ],
    }
    scores = parse_epss_payload(payload)
    assert scores == {"CVE-2023-32681": (0.42, 0.97)}

    ghsa = CVERecord(id="GHSA-j8r2-6x86-q33q", aliases=["CVE-2023-32681"])
    apply_epss([ghsa], scores)
    assert ghsa.epss_score == 0.42
    assert ghsa.epss_percentile == 0.97


def test_fetch_epss_scores_mock_transport():
    import json
    import httpx
    from backend.ingestion.vuln_intel import fetch_epss_scores

    seen_params = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen_params.append(dict(request.url.params))
        return httpx.Response(
            200,
            json={
                "data": [
                    {"cve": "CVE-2021-44228", "epss": "0.975", "percentile": "0.999"}
                ]
            },
        )

    client = httpx.Client(transport=httpx.MockTransport(handler))
    scores = fetch_epss_scores(["CVE-2021-44228", "GHSA-ignored"], client=client)
    assert scores == {"CVE-2021-44228": (0.975, 0.999)}
    assert seen_params == [{"cve": "CVE-2021-44228"}]


def test_index_vuln_vectors_links_qdrant_point_ids(monkeypatch):
    from backend.ingestion.vuln_intel import (
        CVERecord,
        VersionRange,
        format_cve_text,
        index_vuln_vectors,
    )

    monkeypatch.setattr("backend.ingestion.chunk_embed.embed_text", lambda text: [0.1, 0.2])
    monkeypatch.setattr(
        "backend.ingestion.chunk_embed.embed_text_sparse",
        lambda text: {"indices": [1], "values": [0.9]},
    )

    class FakeQdrant:
        def __init__(self):
            self.upserted = []

        def insert_points(self, collection, vectors, sparse_vectors=None, payloads=None, tenant_id="default"):
            self.upserted.append((collection, payloads or []))
            return [p.get("point_id") for p in (payloads or [])]

    rec = CVERecord(
        id="CVE-2024-7777",
        description="Remote code execution in widgetlib",
        severity="CRITICAL",
        kev=True,
        epss_score=0.91,
        cwe_ids=["CWE-94"],
        affected=[VersionRange(product="widgetlib")],
    )
    text = format_cve_text(rec)
    assert "CVE-2024-7777" in text and "[CISA KEV]" in text and "EPSS 0.910" in text

    qdrant = FakeQdrant()
    count = index_vuln_vectors(qdrant, [rec], tenant_id="t1", collection_name="test_col")
    assert count == 1
    assert len(rec.qdrant_point_ids) == 1
    col, payloads = qdrant.upserted[0]
    assert col == "test_col"
    assert payloads[0]["point_id"] == rec.qdrant_point_ids[0]
    assert payloads[0]["source_type"] == "vuln_intel"
    assert payloads[0]["cve_id"] == "CVE-2024-7777"
    assert rec.properties("t1")["qdrant_point_ids"] == rec.qdrant_point_ids


def test_parse_cyclonedx_and_spdx_sbom(tmp_path):
    import json
    from backend.ingestion.dependencies import (
        extract_dependencies_from_repo,
        parse_sbom_json_text,
    )

    cdx = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "components": [
            {"name": "gin", "version": "1.9.1", "purl": "pkg:golang/github.com/gin-gonic/gin@1.9.1"},
            {"name": "log4j-core", "version": "2.14.1", "purl": "pkg:maven/org.apache.logging.log4j/log4j-core@2.14.1"},
            {"name": "serde", "version": "1.0.200", "purl": "pkg:cargo/serde@1.0.200"},
            {"name": "foo", "version": "2.0.0", "purl": "pkg:npm/%40acme/foo@2.0.0"},
        ],
    }
    spdx = {
        "spdxVersion": "SPDX-2.3",
        "packages": [
            {
                "name": "requests",
                "versionInfo": "2.31.0",
                "externalRefs": [
                    {"referenceType": "purl", "referenceLocator": "pkg:pypi/requests@2.31.0"}
                ],
            }
        ],
    }

    cdx_records = parse_sbom_json_text(json.dumps(cdx), source_file="app.cdx.json")
    assert {(r["ecosystem"], r["name"], r["version"]) for r in cdx_records} == {
        ("go", "github.com/gin-gonic/gin", "1.9.1"),
        ("maven", "org.apache.logging.log4j:log4j-core", "2.14.1"),
        ("crates.io", "serde", "1.0.200"),
        ("npm", "@acme/foo", "2.0.0"),
    }

    (tmp_path / "app.cdx.json").write_text(json.dumps(cdx), encoding="utf-8")
    (tmp_path / "app.spdx.json").write_text(json.dumps(spdx), encoding="utf-8")
    repo_records = extract_dependencies_from_repo(tmp_path)
    assert len(repo_records) == 5
    assert any(r["ecosystem"] == "pypi" and r["name"] == "requests" for r in repo_records)


def test_parse_and_write_sarif_findings(monkeypatch):
    from backend.ingestion.sarif import parse_sarif_payload, write_sarif_findings

    monkeypatch.setattr("backend.ingestion.chunk_embed.embed_text", lambda text: [0.1, 0.2])
    monkeypatch.setattr(
        "backend.ingestion.chunk_embed.embed_text_sparse",
        lambda text: {"indices": [1], "values": [0.9]},
    )

    sarif = {
        "version": "2.1.0",
        "runs": [
            {
                "tool": {
                    "driver": {
                        "name": "Semgrep",
                        "rules": [
                            {
                                "id": "python.lang.security.audit.sqli",
                                "properties": {"tags": ["CWE-89", "security"]},
                            }
                        ],
                    }
                },
                "results": [
                    {
                        "ruleId": "python.lang.security.audit.sqli",
                        "level": "error",
                        "message": {"text": "Possible SQL injection"},
                        "locations": [
                            {
                                "physicalLocation": {
                                    "artifactLocation": {"uri": "app/db.py"},
                                    "region": {"startLine": 42},
                                }
                            }
                        ],
                        "codeFlows": [
                            {
                                "threadFlows": [
                                    {
                                        "locations": [
                                            {"location": {"physicalLocation": {"artifactLocation": {"uri": "app/api.py"}, "region": {"startLine": 10}}}},
                                            {"location": {"physicalLocation": {"artifactLocation": {"uri": "app/db.py"}, "region": {"startLine": 42}}}},
                                        ]
                                    }
                                ]
                            }
                        ],
                    }
                ],
            }
        ],
    }

    findings = parse_sarif_payload(sarif)
    assert len(findings) == 1
    assert findings[0]["tool"] == "Semgrep"
    assert findings[0]["severity"] == "HIGH"
    assert findings[0]["cwe_ids"] == ["CWE-89"]
    assert findings[0]["path"] == "app/db.py"
    assert findings[0]["line"] == 42
    assert findings[0]["taint_path"] == ["app/api.py:10", "app/db.py:42"]

    neo4j = RecordingWriteClient()

    class FakeQdrant:
        def __init__(self):
            self.points = []

        def insert_points(self, col, vectors, sparse_vectors=None, payloads=None, tenant_id="default"):
            self.points.extend(payloads or [])
            return [p.get("point_id") for p in (payloads or [])]

    qdrant = FakeQdrant()
    counts = write_sarif_findings(neo4j, findings, tenant_id="t1", qdrant_client=qdrant)
    assert counts == {
        "findings_written": 1,
        "file_links": 1,
        "cwe_links": 1,
        "vectors_written": 1,
    }
    assert len(qdrant.points) == 1
    assert qdrant.points[0]["source_type"] == "sast_sarif"


def test_parse_and_write_mitre_attack_stix(monkeypatch):
    from backend.ingestion.attack_intel import (
        parse_attack_stix_payload,
        write_attack_intel,
    )

    monkeypatch.setattr("backend.ingestion.chunk_embed.embed_text", lambda text: [0.1, 0.2])
    monkeypatch.setattr(
        "backend.ingestion.chunk_embed.embed_text_sparse",
        lambda text: {"indices": [1], "values": [0.9]},
    )

    stix = {
        "type": "bundle",
        "objects": [
            {
                "type": "x-mitre-tactic",
                "id": "x-mitre-tactic--1",
                "name": "Initial Access",
                "x_mitre_shortname": "initial-access",
                "external_references": [{"source_name": "mitre-attack", "external_id": "TA0001"}],
            },
            {
                "type": "attack-pattern",
                "id": "attack-pattern--1",
                "name": "Exploit Public-Facing Application",
                "description": "Adversaries may exploit CWE-89 SQLi.",
                "kill_chain_phases": [{"kill_chain_name": "mitre-attack", "phase_name": "initial-access"}],
                "external_references": [
                    {"source_name": "mitre-attack", "external_id": "T1190"},
                    {"source_name": "cwe", "external_id": "CWE-89"},
                ],
            },
            {
                "type": "course-of-action",
                "id": "course-of-action--1",
                "name": "Application Isolation and Sandboxing",
                "external_references": [{"source_name": "mitre-attack", "external_id": "M1048"}],
            },
            {
                "type": "relationship",
                "relationship_type": "mitigates",
                "source_ref": "course-of-action--1",
                "target_ref": "attack-pattern--1",
            },
        ],
    }

    parsed = parse_attack_stix_payload(stix)
    assert len(parsed["techniques"]) == 1
    assert parsed["techniques"][0]["id"] == "T1190"
    assert parsed["techniques"][0]["cwe_ids"] == ["CWE-89"]
    assert parsed["mitigates"] == [{"mitigation_id": "M1048", "technique_id": "T1190"}]

    neo4j = RecordingWriteClient()

    class FakeQdrant:
        def __init__(self):
            self.points = []

        def insert_points(self, col, vectors, sparse_vectors=None, payloads=None, tenant_id="default"):
            self.points.extend(payloads or [])
            return [p.get("point_id") for p in (payloads or [])]

    qdrant = FakeQdrant()
    counts = write_attack_intel(neo4j, parsed, tenant_id="t1", qdrant_client=qdrant)
    assert counts == {
        "techniques_written": 1,
        "tactics_written": 1,
        "mitigations_written": 1,
        "mitigates_links": 1,
        "vectors_written": 1,
    }
    assert qdrant.points[0]["source_type"] == "mitre_attack"
    assert qdrant.points[0]["technique_id"] == "T1190"


def test_parse_and_write_nuclei_recon_findings(monkeypatch):
    import json
    from backend.ingestion.recon import parse_nuclei_output, write_recon_findings

    monkeypatch.setattr("backend.ingestion.chunk_embed.embed_text", lambda text: [0.1, 0.2])
    monkeypatch.setattr(
        "backend.ingestion.chunk_embed.embed_text_sparse",
        lambda text: {"indices": [1], "values": [0.9]},
    )

    jsonl = json.dumps(
        {
            "template-id": "CVE-2021-44228",
            "matched-at": "https://api.example.com/login",
            "info": {
                "name": "Log4j RCE",
                "severity": "critical",
                "classification": {"cve-id": ["CVE-2021-44228"], "cwe-id": ["CWE-502"]},
            },
        }
    )
    findings = parse_nuclei_output(jsonl)
    assert len(findings) == 1
    assert findings[0]["host"] == "api.example.com"
    assert findings[0]["cve_ids"] == ["CVE-2021-44228"]
    assert findings[0]["cwe_ids"] == ["CWE-502"]

    neo4j = RecordingWriteClient()

    class FakeQdrant:
        def __init__(self):
            self.points = []

        def insert_points(self, col, vectors, sparse_vectors=None, payloads=None, tenant_id="default"):
            self.points.extend(payloads or [])
            return [p.get("point_id") for p in (payloads or [])]

    qdrant = FakeQdrant()
    counts = write_recon_findings(neo4j, findings, tenant_id="t1", qdrant_client=qdrant)
    assert counts == {
        "findings_written": 1,
        "host_links": 1,
        "cve_links": 1,
        "cwe_links": 1,
        "vectors_written": 1,
    }
    assert qdrant.points[0]["source_type"] == "dast_nuclei"


def test_parse_and_write_soc_alerts_and_security_benchmark(monkeypatch):
    from backend.evaluation.security_benchmark import run_security_benchmark
    from backend.ingestion.alerts import parse_alert_payload, write_security_alerts

    monkeypatch.setattr("backend.ingestion.chunk_embed.embed_text", lambda text: [0.1, 0.2])
    monkeypatch.setattr(
        "backend.ingestion.chunk_embed.embed_text_sparse",
        lambda text: {"indices": [1], "values": [0.9]},
    )

    alerts = parse_alert_payload(
        {
            "title": "PowerShell Execution T1059.001",
            "severity": "high",
            "host": "web-01",
            "source_ip": "198.51.100.42",
            "cve_ids": ["CVE-2024-3094"],
        }
    )
    neo4j = RecordingWriteClient()

    class FakeQdrant:
        def __init__(self):
            self.points = []

        def insert_points(self, col, vectors, sparse_vectors=None, payloads=None, tenant_id="default"):
            self.points.extend(payloads or [])
            return [p.get("point_id") for p in (payloads or [])]

    qdrant = FakeQdrant()
    counts = write_security_alerts(neo4j, alerts, tenant_id="t1", qdrant_client=qdrant)
    assert counts == {
        "alerts_written": 1,
        "ioc_links": 1,
        "technique_links": 1,
        "cve_links": 1,
        "vectors_written": 1,
    }
    assert qdrant.points[0]["source_type"] == "soc_alert"

    bench = run_security_benchmark()
    assert bench["passed"] == bench["total"] == 6
    assert bench["pass_rate"] == 1.0
