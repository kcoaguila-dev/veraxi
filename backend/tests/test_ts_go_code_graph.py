"""Tests for TypeScript/JavaScript and Go cross-file tree-sitter resolution (Slice 2)."""

from __future__ import annotations

from backend.evaluation.ts_code_accuracy import evaluate_ts_accuracy
from backend.ingestion.code_graph import parse_repo


def test_ts_code_accuracy_full_recall_and_precision():
    report = evaluate_ts_accuracy()
    assert report["fp"] == 0, f"Unexpected false positives: {report['per_case']}"
    assert report["fn"] == 0, f"Missed TS/JS calls: {report['per_case']}"
    assert report["precision"] == 1.0
    assert report["recall"] == 1.0


def test_ts_cross_file_imports_and_inherits(tmp_path):
    (tmp_path / "src").mkdir()
    (tmp_path / "src" / "base.ts").write_text(
        "export class Base { greet(): void {} }\n", encoding="utf-8"
    )
    (tmp_path / "src" / "sub.ts").write_text(
        "import { Base } from './base';\n"
        "export class Sub extends Base {\n"
        "  run(): void { this.greet(); }\n"
        "}\n",
        encoding="utf-8",
    )
    graph = parse_repo(tmp_path)
    edge_tuples = {(e.type, e.source_qn, e.target_qn) for e in graph.edges}
    assert ("IMPORTS", "sub", "base") in edge_tuples
    assert ("INHERITS", "sub.Sub", "base.Base") in edge_tuples
    assert ("CALLS", "sub.Sub.run", "base.Base.greet") in edge_tuples


def test_go_cross_file_package_and_receiver_calls(tmp_path):
    (tmp_path / "go.mod").write_text("module example.com/myrepo\n\ngo 1.22\n", encoding="utf-8")
    (tmp_path / "internal" / "svc").mkdir(parents=True)
    (tmp_path / "internal" / "svc" / "service.go").write_text(
        "package svc\n\n"
        "func Process() string {\n"
        "    return helper()\n"
        "}\n\n"
        "type Server struct{}\n\n"
        "func (s *Server) Handle() {\n"
        "    s.respond()\n"
        "}\n\n"
        "func (s *Server) respond() {}\n",
        encoding="utf-8",
    )
    (tmp_path / "internal" / "svc" / "helper.go").write_text(
        "package svc\n\nfunc helper() string {\n    return \"ok\"\n}\n",
        encoding="utf-8",
    )
    (tmp_path / "cmd").mkdir()
    (tmp_path / "cmd" / "main.go").write_text(
        "package main\n\n"
        "import \"example.com/myrepo/internal/svc\"\n\n"
        "func main() {\n"
        "    svc.Process()\n"
        "    srv := &svc.Server{}\n"
        "    srv.Handle()\n"
        "}\n",
        encoding="utf-8",
    )
    graph = parse_repo(tmp_path)
    calls = {(e.source_qn, e.target_qn) for e in graph.edges if e.type == "CALLS"}
    # Cross-package call: main -> svc.Process
    assert any(src.endswith(".main") and dst.endswith(".Process") for src, dst in calls), calls
    # Same-package cross-file call: Process -> helper
    assert any(src.endswith(".Process") and dst.endswith(".helper") for src, dst in calls), calls
    # Receiver method call within Server: Handle -> respond
    assert any(src.endswith(".Server.Handle") and dst.endswith(".Server.respond") for src, dst in calls), calls
    # Cross-package struct instantiation + method call: main -> Server.Handle
    assert any(src.endswith(".main") and dst.endswith(".Server.Handle") for src, dst in calls), calls
