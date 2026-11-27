"""Tests for AST-aware code chunking, identifier splitting, and code embedding config (Slice 3)."""

from __future__ import annotations

from backend.config import Config
from backend.ingestion.chunk_embed import chunk_code, expand_code_identifiers


def test_expand_code_identifiers_camel_and_snake():
    out_camel = expand_code_identifiers("def buildVideoItem(userId):")
    assert "buildVideoItem" in out_camel
    assert "build" in out_camel and "video" in out_camel and "item" in out_camel
    assert "user" in out_camel and "id" in out_camel

    out_snake = expand_code_identifiers("get_user_by_id(session_token)")
    assert "get_user_by_id" in out_snake
    assert "get" in out_snake and "user" in out_snake and "by" in out_snake and "id" in out_snake

    out_acronym = expand_code_identifiers("HTTPServerConfig")
    assert "HTTPServerConfig" in out_acronym
    assert "http" in out_acronym and "server" in out_acronym and "config" in out_acronym


def test_chunk_code_python_ast_boundaries_and_headers():
    source = (
        "import os\n\n"
        "def alpha_helper(x: int) -> int:\n"
        "    return x + 1\n\n"
        "class WorkerService:\n"
        "    def run(self) -> None:\n"
        "        pass\n"
    )
    chunks = chunk_code(source, "backend/worker.py", chunk_size=500)
    assert len(chunks) >= 2
    assert any("def alpha_helper" in c and "backend/worker.py" in c and "alpha_helper" in c for c in chunks)
    assert any("class WorkerService" in c and "backend/worker.py" in c and "WorkerService" in c for c in chunks)
    # Neither function nor class should be split mid-body here
    alpha_chunks = [c for c in chunks if "def alpha_helper" in c]
    assert len(alpha_chunks) == 1
    assert "return x + 1" in alpha_chunks[0]


def test_chunk_code_treesitter_ts_and_go_boundaries():
    ts_src = (
        "export function greetUser(name: string): string {\n"
        "  return `hi ${name}`;\n"
        "}\n\n"
        "export class Greeter {\n"
        "  hello(): void {}\n"
        "}\n"
    )
    ts_chunks = chunk_code(ts_src, "src/greeter.ts", chunk_size=500)
    assert len(ts_chunks) >= 2
    assert any("src/greeter.ts" in c and "greetUser" in c for c in ts_chunks)
    assert any("src/greeter.ts" in c and "Greeter" in c for c in ts_chunks)

    go_src = (
        "package main\n\n"
        "func BuildServer() {}\n\n"
        "func StartServer() {}\n"
    )
    go_chunks = chunk_code(go_src, "cmd/server.go", chunk_size=500)
    assert len(go_chunks) >= 2
    assert any("cmd/server.go" in c and "BuildServer" in c for c in go_chunks)
    assert any("cmd/server.go" in c and "StartServer" in c for c in go_chunks)


def test_code_embedding_config_dedicated_collection(monkeypatch):
    baseline = Config.from_env()
    monkeypatch.setenv("CODE_EMBEDDING_MODEL", "jinaai/jina-embeddings-v2-base-code")
    monkeypatch.delenv("CODE_EMBEDDING_DIMENSION", raising=False)
    monkeypatch.delenv("CODE_QDRANT_COLLECTION", raising=False)
    cfg = Config.from_env()
    assert cfg.code_embedding_model_name == "jinaai/jina-embeddings-v2-base-code"
    assert cfg.code_embedding_dimension == 768
    assert cfg.code_qdrant_collection_name == "veraxi_code_chunks"
    # Standard collection and dimension remain untouched
    assert cfg.embedding_dimension == baseline.embedding_dimension
    assert cfg.qdrant_collection_name == baseline.qdrant_collection_name
