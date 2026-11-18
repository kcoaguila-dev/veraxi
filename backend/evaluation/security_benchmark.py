"""Deterministic multi-hop Cybersecurity & Code-Intelligence Benchmark.

Zero-cost, offline evaluation suite scoring Veraxi's 6 security/code pillars:
1. Tree-sitter polyglot code graph (Go / JS / Python CALLS & IMPORTS)
2. Fail-closed CVE + KEV + EPSS prioritization
3. CycloneDX / SPDX SBOM parsing
4. SARIF 2.1.0 taint codeFlows extraction
5. Nuclei recon / DAST + MITRE ATT&CK STIX 2.1 mapping
6. SOC Alert & IOC correlation
"""

from __future__ import annotations

import json
import tempfile
from pathlib import Path
from typing import Any

from backend.ingestion.alerts import parse_alert_payload
from backend.ingestion.attack_intel import parse_attack_stix_payload
from backend.ingestion.code_graph import parse_repo
from backend.ingestion.dependencies import parse_sbom_json_text
from backend.ingestion.recon import parse_nuclei_output
from backend.ingestion.sarif import parse_sarif_payload
from backend.retrieval.vuln_queries import match_dependencies


def run_security_benchmark() -> dict[str, Any]:
    """Run all deterministic security/code-intel benchmark cases."""
    cases: list[dict[str, Any]] = []

    # 1. Tree-sitter polyglot code graph
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "main.go").write_text(
            'package main\nimport "net/http"\nfunc auth() {}\nfunc serve() { auth() }\n',
            encoding="utf-8",
        )
        (root / "api.ts").write_text(
            'import express from "express";\nfunction validate() {}\nfunction route() { validate(); }\n',
            encoding="utf-8",
        )
        cg = parse_repo(root)
        calls = {(e.source_qn, e.target_qn) for e in cg.edges if e.type == "CALLS"}
        passed = ("main.serve", "main.auth") in calls and ("api.route", "api.validate") in calls
        cases.append({"name": "treesitter_polyglot_calls", "passed": passed})

    # 2. Fail-closed CVE + KEV + EPSS prioritization
    deps = [
        {"name": "pkg", "version": "1.2.0", "ecosystem": "pypi", "source_file": "uv.lock"},
        {"name": "pkg", "version": "1.2.0rc1", "ecosystem": "pypi", "source_file": "uv.lock"},
    ]
    index = {
        "pypi:pkg": [
            {
                "cve_id": "CVE-2024-0001",
                "severity": "MEDIUM",
                "kev": False,
                "epss_score": 0.1,
                "version_start_including": "1.0.0",
                "version_end_excluding": "2.0.0",
            },
            {
                "cve_id": "CVE-2024-0002",
                "severity": "HIGH",
                "kev": True,
                "epss_score": 0.05,
                "version_start_including": "1.0.0",
                "version_end_excluding": "2.0.0",
            },
        ]
    }
    findings = match_dependencies(deps, index)
    passed = (
        len(findings) == 4
        and findings[0]["cve_id"] == "CVE-2024-0002"
        and findings[0]["match_status"] == "matched"
        and all(f["match_status"] == "unknown" for f in findings[2:])
    )
    cases.append({"name": "fail_closed_kev_epss_ranking", "passed": passed})

    # 3. CycloneDX SBOM parsing
    cdx = json.dumps(
        {
            "bomFormat": "CycloneDX",
            "components": [
                {"name": "gin", "version": "1.9.1", "purl": "pkg:golang/github.com/gin-gonic/gin@1.9.1"},
                {"name": "serde", "version": "1.0.200", "purl": "pkg:cargo/serde@1.0.200"},
            ],
        }
    )
    sbom_deps = parse_sbom_json_text(cdx, source_file="bom.json")
    passed = {(d["ecosystem"], d["name"]) for d in sbom_deps} == {
        ("go", "github.com/gin-gonic/gin"),
        ("crates.io", "serde"),
    }
    cases.append({"name": "cyclonedx_sbom_purl", "passed": passed})

    # 4. SARIF taint codeFlows
    sarif = parse_sarif_payload(
        {
            "runs": [
                {
                    "tool": {"driver": {"name": "Semgrep", "rules": []}},
                    "results": [
                        {
                            "ruleId": "sqli",
                            "level": "error",
                            "message": {"text": "SQLi CWE-89"},
                            "locations": [
                                {"physicalLocation": {"artifactLocation": {"uri": "db.py"}, "region": {"startLine": 12}}}
                            ],
                            "codeFlows": [
                                {
                                    "threadFlows": [
                                        {
                                            "locations": [
                                                {"location": {"physicalLocation": {"artifactLocation": {"uri": "api.py"}, "region": {"startLine": 4}}}},
                                                {"location": {"physicalLocation": {"artifactLocation": {"uri": "db.py"}, "region": {"startLine": 12}}}},
                                            ]
                                        }
                                    ]
                                }
                            ],
                        }
                    ],
                }
            ]
        }
    )
    passed = len(sarif) == 1 and sarif[0]["taint_path"] == ["api.py:4", "db.py:12"] and sarif[0]["cwe_ids"] == ["CWE-89"]
    cases.append({"name": "sarif_taint_codeflows", "passed": passed})

    # 5. Nuclei recon + MITRE ATT&CK
    recon = parse_nuclei_output(
        '{"template-id":"CVE-2021-44228","matched-at":"https://api.test/","info":{"name":"Log4j","severity":"critical","classification":{"cve-id":["CVE-2021-44228"]}}}'
    )
    attack = parse_attack_stix_payload(
        {
            "objects": [
                {
                    "type": "attack-pattern",
                    "id": "attack-pattern--1",
                    "name": "Exploit Public-Facing App",
                    "external_references": [{"source_name": "mitre-attack", "external_id": "T1190"}],
                }
            ]
        }
    )
    passed = recon[0]["host"] == "api.test" and attack["techniques"][0]["id"] == "T1190"
    cases.append({"name": "nuclei_and_mitre_attack", "passed": passed})

    # 6. SOC Alert & IOC correlation
    alerts = parse_alert_payload(
        {
            "title": "Suspicious PowerShell T1059.001",
            "severity": "high",
            "host": "web-01",
            "source_ip": "198.51.100.42",
            "cve_ids": ["CVE-2024-3094"],
        }
    )
    passed = (
        alerts[0]["technique_ids"] == ["T1059.001"]
        and alerts[0]["cve_ids"] == ["CVE-2024-3094"]
        and alerts[0]["iocs"] == [{"value": "198.51.100.42", "kind": "ip"}]
    )
    cases.append({"name": "soc_alert_ioc_extraction", "passed": passed})

    passed_count = sum(1 for c in cases if c["passed"])
    return {
        "total": len(cases),
        "passed": passed_count,
        "pass_rate": passed_count / len(cases),
        "cases": cases,
    }


if __name__ == "__main__":
    print(json.dumps(run_security_benchmark(), indent=2))
