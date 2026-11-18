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
