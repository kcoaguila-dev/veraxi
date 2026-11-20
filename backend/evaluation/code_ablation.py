"""Offline repository code-graph ablation retriever.

Builds an in-memory structural code graph (via ``backend.ingestion.code_graph.parse_repo``),
subword semantic/prose index, and exact-identifier BM25 index over a local
repository tree with no external database, network, or LLM calls.

Used by ``backend.evaluation.ablation.run_ablation`` to compare:
- ``vector_only``: subword/conceptual TF-IDF cosine ranking
- ``hybrid_no_graph``: dense subword ranking fused with exact-identifier BM25
- ``hybrid_with_graph``: hybrid ranking fused with AST graph lookup,
  transitive caller/importer traversal (``impact_analysis``), and
  repository hub centrality (``repo_overview``) via ``merge_rank``.
"""

from __future__ import annotations

import math
import re
from collections import Counter
from pathlib import Path
from typing import Any

from backend.evaluation.ablation import RetrievalResult
from backend.ingestion.code_graph import CodeGraph, parse_repo
from backend.retrieval.code_queries import (
    IMPACT_EDGE_TYPES,
    impact_analysis,
    repo_overview,
    symbol_lookup,
)
from backend.retrieval.merge_rank import GraphHit, VectorHit, merge_rank

_STOPWORDS = frozenset(
    {
        "a",
        "an",
        "and",
        "are",
        "as",
        "at",
        "be",
        "by",
        "do",
        "does",
        "for",
        "from",
        "how",
        "if",
        "in",
        "into",
        "is",
        "it",
        "its",
        "of",
        "on",
        "or",
        "so",
        "that",
        "the",
        "their",
        "them",
        "these",
        "this",
        "through",
        "to",
        "what",
        "when",
        "where",
        "which",
        "who",
        "with",
    }
)

_RIPPLE_CUES = frozenset(
    {
        "call",
        "called",
        "caller",
        "callers",
        "calls",
        "change",
        "changes",
        "depend",
        "depends",
        "dispatch",
        "downstream",
        "impact",
        "impacted",
        "import",
        "imported",
        "importer",
        "importers",
        "invoke",
        "invokes",
        "ripple",
        "test",
        "tests",
    }
)

_GLOBAL_CUES = frozenset(
    {
        "across",
        "architecture",
        "central",
        "connected",
        "corpus",
        "hub",
        "hubs",
        "overview",
        "pipeline",
        "repository",
        "summarize",
        "whole",
    }
)

_CAMEL_RE = re.compile(r"[A-Z]+(?=[A-Z][a-z]|\b)|[A-Z]?[a-z]+|[0-9]+")
_IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*")
_DOCSTRING_RE = re.compile(r'"""(.*?)"""|\'\'\'(.*?)\'\'\'', re.DOTALL)
_COMMENT_RE = re.compile(r"(?:^|\s)(?:#|//+|///)\s*(.+)")


def _extract_conceptual_text(path: str, source: str) -> str:
    """Extract natural-language prose (path words, docstrings, and comments)."""
    parts = [path.replace("/", " ").replace(".", " ")]
    for triple_d, triple_s in _DOCSTRING_RE.findall(source):
        chunk = triple_d or triple_s
        if chunk:
            parts.append(chunk)
    for comment in _COMMENT_RE.findall(source):
        parts.append(comment)
    joined = "\n".join(parts)
    # Fall back to source only if no comments/docstrings were present.
    return joined if len(parts) > 1 else f"{path}\n{source}"


def _tokenize_prose(text: str) -> list[str]:
    """Tokenize into lowercase natural-language subwords (splits Camel/snake)."""
    tokens: list[str] = []
    for raw in re.findall(r"[A-Za-z0-9]+", text):
        parts = _CAMEL_RE.findall(raw)
        for part in parts:
            word = part.lower()
            if len(word) >= 2 and word not in _STOPWORDS:
                tokens.append(word)
    return tokens


def _tokenize_identifiers(text: str) -> list[str]:
    """Tokenize preserving exact identifiers, dotted paths, and lexical words."""
    tokens: list[str] = []
    for match in _IDENT_RE.findall(text):
        lowered = match.lower()
        if len(lowered) < 2 or lowered in _STOPWORDS:
            continue
        if "." in match:
            tokens.append(f"qn:{lowered}")
            for segment in match.split("."):
                seg_l = segment.lower()
                if len(seg_l) >= 2 and seg_l not in _STOPWORDS:
                    tokens.append(f"id:{segment}")
                    tokens.append(seg_l)
        else:
            tokens.append(f"id:{match}")
            tokens.append(lowered)
    return tokens


def _extract_symbol_candidates(
    query: str, known_names: set[str], known_qns: set[str]
) -> list[str]:
    """Extract plausible symbol / module names from a developer query."""
    candidates: list[str] = []
    seen: set[str] = set()
    for token in _IDENT_RE.findall(query):
        is_compound = (
            "." in token
            or "_" in token
            or any(c.isupper() for c in token[1:])
        )
        if token in known_qns or token in known_names or is_compound:
            if token not in seen:
                seen.add(token)
                candidates.append(token)
    return candidates


class InMemoryCodeGraphClient:
    """In-memory ``CodeGraphClient`` backed by a parsed ``CodeGraph``."""

    def __init__(self, graph: CodeGraph) -> None:
        self.graph = graph
        self._by_qn = {node.qualified_name: node for node in graph.nodes}

    def _row(self, node: Any) -> dict[str, Any]:
        return {
            "label": node.label,
            "name": node.name,
            "qualified_name": node.qualified_name,
            "path": node.path,
            "line": node.line,
            "language": node.language,
            "resolved": node.resolved,
        }

    def find_symbols(
        self,
        tenant_id: str,
        *,
        qualified_name: str | None = None,
        name: str | None = None,
    ) -> list[dict[str, Any]]:
        """Return matching nodes by qualified name or simple name."""
        if qualified_name is not None:
            return [
                self._row(n)
                for n in self.graph.nodes
                if n.resolved and n.qualified_name == qualified_name
            ]
        if name is not None:
            return [
                self._row(n)
                for n in self.graph.nodes
                if n.resolved and n.name == name
            ]
        return []

    def incoming_edges(
        self, tenant_id: str, target_qns: list[str]
    ) -> list[dict[str, Any]]:
        """Return resolved incoming ``CALLS`` / ``IMPORTS`` edges."""
        targets = set(target_qns)
        rows: list[dict[str, Any]] = []
        for edge in self.graph.edges:
            if edge.type not in IMPACT_EDGE_TYPES or edge.target_qn not in targets:
                continue
            source = self._by_qn.get(edge.source_qn)
            if source is None or not source.resolved:
                continue
            rows.append(
                {
                    "source_qn": edge.source_qn,
                    "source_name": source.name,
                    "source_label": source.label,
                    "source_path": source.path,
                    "edge_type": edge.type,
                    "target_qn": edge.target_qn,
                }
            )
        return rows

    def outgoing_paths(self, source_qns: set[str]) -> list[str]:
        """Return file paths of resolved outgoing ``CALLS`` / ``IMPORTS`` targets."""
        paths: list[str] = []
        for edge in self.graph.edges:
            if edge.type not in IMPACT_EDGE_TYPES or edge.source_qn not in source_qns:
                continue
            target = self._by_qn.get(edge.target_qn)
            if target is not None and target.resolved and target.path:
                paths.append(target.path)
        return paths

    def _scoped_nodes(self, path_prefix: str | None) -> list[Any]:
        return [
            node
            for node in self.graph.nodes
            if node.resolved
            and (path_prefix is None or node.path.startswith(path_prefix))
        ]

    def node_counts(
        self, tenant_id: str, path_prefix: str | None = None
    ) -> dict[str, int]:
        """Count resolved nodes per label within optional path prefix."""
        return dict(Counter(node.label for node in self._scoped_nodes(path_prefix)))

    def edge_counts(
        self, tenant_id: str, path_prefix: str | None = None
    ) -> dict[str, int]:
        """Count edges originating in scoped nodes."""
        scoped = {node.qualified_name for node in self._scoped_nodes(path_prefix)}
        return dict(
            Counter(
                edge.type for edge in self.graph.edges if edge.source_qn in scoped
            )
        )

    def top_connected(
        self, tenant_id: str, path_prefix: str | None = None, limit: int = 10
    ) -> list[dict[str, Any]]:
        """Return highest-degree resolved code nodes within optional path prefix."""
        degree: Counter[str] = Counter()
        for edge in self.graph.edges:
            degree[edge.source_qn] += 1
            degree[edge.target_qn] += 1
        rows = [
            {
                "qualified_name": node.qualified_name,
                "name": node.name,
                "label": node.label,
                "path": node.path,
                "connections": degree[node.qualified_name],
            }
            for node in self._scoped_nodes(path_prefix)
            if node.path
        ]
        rows.sort(key=lambda r: (-int(r["connections"]), str(r["qualified_name"])))
        return rows[:limit]


class RepoCodeAblationRetriever:
    """Offline code retriever implementing ``vector_only``, ``hybrid_no_graph``,
    and ``hybrid_with_graph`` over a local repository tree."""

    def __init__(
        self,
        repo_root: str | Path,
        *,
        candidate_pool: int = 150,
    ) -> None:
        self.repo_root = Path(repo_root)
        self.candidate_pool = candidate_pool
        self.graph = parse_repo(self.repo_root)
        self._graph_client = InMemoryCodeGraphClient(self.graph)
        self._known_names = {
            n.name for n in self.graph.nodes if n.resolved and n.name
        }
        self._known_qns = {
            n.qualified_name
            for n in self.graph.nodes
            if n.resolved and n.qualified_name
        }
        self._docs = self._load_source_files()
        self._doc_paths = sorted(self._docs)
        self._prose_docs = {
            path: _extract_conceptual_text(path, text)
            for path, text in self._docs.items()
        }
        self._prose_tf, self._prose_idf, self._prose_norms = self._build_tfidf(
            self._prose_docs, _tokenize_prose
        )
        (
            self._ident_tf,
            self._ident_idf,
            self._ident_lens,
            self._ident_avg_len,
        ) = self._build_bm25_stats(self._docs, _tokenize_identifiers)

    def _load_source_files(self) -> dict[str, str]:
        docs: dict[str, str] = {}
        for node in self.graph.nodes:
            if node.label != "CodeFile" or not node.resolved or not node.path:
                continue
            if "/ephemeral/" in node.path or node.path == "backend/evaluation/code_ablation.py":
                continue
            if node.path in docs:
                continue
            file_path = self.repo_root / node.path
            try:
                text = file_path.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            docs[node.path] = f"{node.path}\n{text}"
        return docs

    def _build_tfidf(
        self, corpus: dict[str, str], tokenizer: Any
    ) -> tuple[dict[str, Counter[str]], dict[str, float], dict[str, float]]:
        tf_by_doc: dict[str, Counter[str]] = {}
        df: Counter[str] = Counter()
        for doc_id, text in corpus.items():
            counts = Counter(tokenizer(text))
            tf_by_doc[doc_id] = counts
            for term in counts:
                df[term] += 1
        n_docs = max(len(corpus), 1)
        idf = {
            term: math.log((n_docs + 1.0) / (freq + 1.0)) + 1.0
            for term, freq in df.items()
        }
        raw_norms: dict[str, float] = {}
        for doc_id, counts in tf_by_doc.items():
            sq_sum = sum(
                ((1.0 + math.log(count)) * idf.get(term, 1.0)) ** 2
                for term, count in counts.items()
            )
            raw_norms[doc_id] = math.sqrt(sq_sum) or 1.0
        avg_norm = sum(raw_norms.values()) / max(len(raw_norms), 1)
        floor = 0.5 * avg_norm
        norms = {doc_id: max(n, floor) or 1.0 for doc_id, n in raw_norms.items()}
        return tf_by_doc, idf, norms

    def _build_bm25_stats(
        self, corpus: dict[str, str], tokenizer: Any
    ) -> tuple[dict[str, Counter[str]], dict[str, float], dict[str, int], float]:
        tf_by_doc: dict[str, Counter[str]] = {}
        df: Counter[str] = Counter()
        lengths: dict[str, int] = {}
        total_len = 0
        for doc_id, text in corpus.items():
            tokens = tokenizer(text)
            lengths[doc_id] = len(tokens)
            total_len += len(tokens)
            counts = Counter(tokens)
            tf_by_doc[doc_id] = counts
            for term in counts:
                df[term] += 1
        n_docs = max(len(corpus), 1)
        idf = {
            term: math.log(1.0 + (n_docs - freq + 0.5) / (freq + 0.5))
            for term, freq in df.items()
        }
        avg_len = (total_len / n_docs) if n_docs else 1.0
        return tf_by_doc, idf, lengths, avg_len

    def _dense_hits(self, query: str) -> list[VectorHit]:
        q_counts = Counter(_tokenize_prose(query))
        if not q_counts:
            return []
        q_weights = {
            term: (1.0 + math.log(count)) * self._prose_idf.get(term, 1.0)
            for term, count in q_counts.items()
        }
        q_norm = math.sqrt(sum(w * w for w in q_weights.values())) or 1.0
        scored: list[tuple[float, str]] = []
        for doc_id in self._doc_paths:
            doc_counts = self._prose_tf[doc_id]
            dot = sum(
                q_w * (1.0 + math.log(doc_counts[term])) * self._prose_idf.get(term, 1.0)
                for term, q_w in q_weights.items()
                if term in doc_counts
            )
            if dot <= 0.0:
                continue
            score = dot / (q_norm * self._prose_norms[doc_id])
            scored.append((score, doc_id))
        scored.sort(key=lambda pair: (-pair[0], pair[1]))
        return [
            VectorHit(id=doc_id, score=score, payload={"path": doc_id})
            for score, doc_id in scored[: self.candidate_pool]
        ]

    def _sparse_bm25_hits(self, query: str) -> list[VectorHit]:
        q_tokens = _tokenize_identifiers(query)
        if not q_tokens:
            return []
        k1 = 1.5
        b = 0.75
        q_counts = Counter(q_tokens)
        scored: list[tuple[float, str]] = []
        avg_len = max(self._ident_avg_len, 1.0)
        for doc_id in self._doc_paths:
            doc_counts = self._ident_tf[doc_id]
            doc_len = self._ident_lens[doc_id]
            norm_factor = k1 * (1.0 - b + b * (doc_len / avg_len))
            score = 0.0
            for term, q_freq in q_counts.items():
                tf = doc_counts.get(term, 0)
                if tf <= 0:
                    continue
                idf = self._ident_idf.get(term, 0.0)
                score += idf * q_freq * ((tf * (k1 + 1.0)) / (tf + norm_factor))
            if score > 0.0:
                scored.append((score, doc_id))
        scored.sort(key=lambda pair: (-pair[0], pair[1]))
        return [
            VectorHit(id=doc_id, score=score, payload={"path": doc_id})
            for score, doc_id in scored[: self.candidate_pool]
        ]

    def _hybrid_vector_hits(self, query: str) -> list[VectorHit]:
        dense = self._dense_hits(query)
        sparse = self._sparse_bm25_hits(query)
        scores: dict[str, float] = {}
        for rank, hit in enumerate(dense, start=1):
            scores[hit.id] = scores.get(hit.id, 0.0) + 1.0 / (60 + rank)
        for rank, hit in enumerate(sparse, start=1):
            scores[hit.id] = scores.get(hit.id, 0.0) + 1.0 / (60 + rank)
        ranked = sorted(scores.items(), key=lambda pair: (-pair[1], pair[0]))
        return [
            VectorHit(id=doc_id, score=score, payload={"path": doc_id})
            for doc_id, score in ranked[: self.candidate_pool]
        ]

    def _collect_symbol_graph_paths(self, query: str) -> list[str]:
        words = {w.lower() for w in re.findall(r"[A-Za-z_]+", query)}
        is_ripple = bool(words & _RIPPLE_CUES)
        candidates = _extract_symbol_candidates(
            query, self._known_names, self._known_qns
        )
        root_paths: list[str] = []
        impact_paths: list[str] = []
        outgoing: list[str] = []
        for candidate in candidates:
            impact = impact_analysis(
                candidate, tenant_id="eval", max_depth=2, client=self._graph_client
            )
            if not impact["found"]:
                lookup = symbol_lookup(
                    candidate, tenant_id="eval", client=self._graph_client
                )
                for m in lookup["matches"]:
                    if m.get("path"):
                        root_paths.append(str(m["path"]))
                continue
            root_qns = {
                str(r["qualified_name"])
                for r in impact["roots"]
                if r.get("qualified_name")
            }
            for r in impact["roots"]:
                if r.get("path"):
                    root_paths.append(str(r["path"]))
            for item in impact["impacted"]:
                if item.get("path"):
                    impact_paths.append(str(item["path"]))
            outgoing.extend(self._graph_client.outgoing_paths(root_qns))
        if is_ripple:
            return [*impact_paths, *root_paths, *outgoing]
        return [*root_paths, *impact_paths, *outgoing]

    def _graph_hits(self, query: str) -> list[GraphHit]:
        ordered_paths = self._collect_symbol_graph_paths(query)
        words = {w.lower() for w in re.findall(r"[A-Za-z_]+", query)}
        if words & _GLOBAL_CUES:
            prefix = "backend/" if "backend" in words else None
            overview = repo_overview(
                tenant_id="eval",
                path_prefix=prefix,
                client=self._graph_client,
                top_limit=10,
            )
            for hub in overview["top_connected"]:
                if hub.get("path"):
                    ordered_paths.append(str(hub["path"]))
        seen: set[str] = set()
        hits: list[GraphHit] = []
        for path in ordered_paths:
            if not path or path not in self._docs or path in seen:
                continue
            seen.add(path)
            hits.append(GraphHit(id=path, payload={"path": path}))
            if len(hits) >= self.candidate_pool:
                break
        return hits

    def retrieve(self, config: str, query: str) -> RetrievalResult:
        """Return ranked repository file paths for ``query`` under ``config``."""
        if config == "vector_only":
            merged = merge_rank(
                self._dense_hits(query),
                [],
                limit=self.candidate_pool,
                rerank=False,
            )
        elif config == "hybrid_no_graph":
            merged = merge_rank(
                self._hybrid_vector_hits(query),
                [],
                limit=self.candidate_pool,
                rerank=False,
            )
        elif config == "hybrid_with_graph":
            merged = merge_rank(
                self._hybrid_vector_hits(query),
                self._graph_hits(query),
                limit=self.candidate_pool,
                rerank=False,
            )
        else:
            raise ValueError(f"Unknown configuration: {config}")
        return RetrievalResult(ranked_doc_ids=tuple(item.id for item in merged))


__all__ = ["InMemoryCodeGraphClient", "RepoCodeAblationRetriever"]
