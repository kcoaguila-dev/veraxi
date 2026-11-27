import ast
import re
from functools import lru_cache
from pathlib import Path
from typing import Any

_CJK_RE = re.compile(r"([\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af])")
_PAGE_SPLIT_RE = re.compile(r"(<!--\s*page:\d+.*?-->)", re.DOTALL)
_IDENT_TOKEN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]{2,}")
_CAMEL_SPLIT_RE = re.compile(r"(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])")

_CODE_EXT_TO_TS = {
    ".ts": "typescript",
    ".tsx": "tsx",
    ".js": "javascript",
    ".jsx": "javascript",
    ".mjs": "javascript",
    ".cjs": "javascript",
    ".go": "go",
    ".dart": "dart",
    ".rs": "rust",
    ".java": "java",
    ".rb": "ruby",
    ".kt": "kotlin",
    ".cs": "c_sharp",
    ".cpp": "cpp",
    ".c": "c",
}
_TS_AST_BLOCK_TYPES = {
    "class_declaration",
    "class_definition",
    "interface_declaration",
    "function_declaration",
    "function_definition",
    "method_declaration",
    "method_definition",
    "function_item",
    "struct_item",
    "type_declaration",
    "export_statement",
}


def is_code_file(file_path: str | None) -> bool:
    """Return True when ``file_path`` has a supported source-code extension."""
    if not file_path:
        return False
    suffix = Path(file_path).suffix.lower()
    return suffix == ".py" or suffix in _CODE_EXT_TO_TS


def expand_code_identifiers(text: str) -> str:
    """Expand camelCase and snake_case identifiers into space-separated sub-tokens.

    Preserves the original identifier so exact and partial identifier queries
    both hit in Qdrant BM25 (e.g. ``buildVideoItem`` -> ``buildVideoItem build video item``).
    """
    if not text:
        return ""

    def _expand_match(m: re.Match[str]) -> str:
        raw = m.group(0)
        parts: list[str] = []
        for snake_part in raw.split("_"):
            if not snake_part:
                continue
            for camel_part in _CAMEL_SPLIT_RE.split(snake_part):
                if camel_part:
                    parts.append(camel_part.lower())
        if len(parts) <= 1:
            return raw
        return f"{raw} {' '.join(parts)}"

    return _IDENT_TOKEN_RE.sub(_expand_match, text)


def _pretokenize_cjk(text: str) -> str:
    """Pad CJK characters with whitespace to prevent BM25 dropping long CJK tokens."""
    if not text:
        return ""
    return _CJK_RE.sub(r" \1 ", text)


def _find_best_split_index(text: str, start: int, end: int, overlap: int) -> int:
    """Finds the best split position within [start + overlap + 1, end], preferring sentence ends over spaces."""
    min_split = start + overlap + 1
    if min_split >= end:
        return end

    search_window = text[min_split:end]

    # 1. Search for sentence terminators followed by whitespace or newline
    best_sent_idx = -1
    for sep in ("\n\n", ".\n", "!\n", "?\n", "\n", ". ", "! ", "? "):
        pos = search_window.rfind(sep)
        if pos != -1:
            candidate = min_split + pos + (1 if sep.startswith((".", "!", "?")) else len(sep))
            if candidate > best_sent_idx and candidate <= end:
                best_sent_idx = candidate

    if best_sent_idx > min_split:
        return best_sent_idx

    # 2. Fall back to word boundary (space)
    space_pos = text.rfind(" ", min_split, end)
    if space_pos > min_split:
        return space_pos

    return end


def _chunk_plain_segment(
    text: str, chunk_size: int = 800, overlap: int = 150
) -> list[str]:
    """Chunk a single plain text segment into segments of chunk_size with overlap."""
    if not text:
        return []

    chunks = []
    start = 0
    text_len = len(text)
    while start < text_len:
        end = min(text_len, start + chunk_size)
        if end < text_len:
            end = _find_best_split_index(text, start, end, overlap)
        chunk = text[start:end]
        chunks.append(chunk)
        if end >= text_len:
            break
        start = max(start + 1, end - overlap)

    return chunks


def chunk_text(text: str, chunk_size: int = 800, overlap: int = 150) -> list[str]:
    """Chunk text into segments of chunk_size with overlap, preserving <!-- page:N --> markers intact."""
    if not text:
        return []
    if "<!-- page:" not in text:
        return _chunk_plain_segment(text, chunk_size=chunk_size, overlap=overlap)

    parts = _PAGE_SPLIT_RE.split(text)
    chunks: list[str] = []
    current_marker = ""
    for part in parts:
        if not part or not part.strip():
            continue
        if _PAGE_SPLIT_RE.fullmatch(part.strip()):
            current_marker = part.strip()
            continue
        for seg in _chunk_plain_segment(
            part.strip(), chunk_size=chunk_size, overlap=overlap
        ):
            chunks.append(f"{current_marker}\n{seg}" if current_marker else seg)
    return chunks


def _python_ast_blocks(text: str) -> list[tuple[str, str]]:
    """Extract (symbol_name, block_text) pairs from Python top-level AST nodes."""
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return []
    lines = text.splitlines(keepends=True)
    blocks: list[tuple[str, str]] = []
    last_end = 0
    for node in tree.body:
        if not isinstance(node, (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        start = max(0, (node.lineno or 1) - 1)
        end = node.end_lineno or len(lines)
        if start > last_end:
            preamble = "".join(lines[last_end:start]).strip()
            if preamble:
                blocks.append(("module", preamble))
        snippet = "".join(lines[start:end]).strip()
        if snippet:
            blocks.append((node.name, snippet))
        last_end = end
    if last_end < len(lines):
        tail = "".join(lines[last_end:]).strip()
        if tail:
            blocks.append(("module", tail))
    return blocks


def _ts_node_symbol_name(node: Any, source: bytes) -> str:
    name_n = node.child_by_field_name("name")
    if name_n is not None:
        return source[name_n.start_byte : name_n.end_byte].decode("utf-8", errors="replace").strip()
    for child in node.children:
        if child.type in ("identifier", "type_identifier", "property_identifier", "simple_identifier"):
            return source[child.start_byte : child.end_byte].decode("utf-8", errors="replace").strip()
        if child.type in _TS_AST_BLOCK_TYPES:
            nested = _ts_node_symbol_name(child, source)
            if nested:
                return nested
    return "block"


def _treesitter_ast_blocks(text: str, lang: str) -> list[tuple[str, str]]:
    """Extract (symbol_name, block_text) pairs from tree-sitter top-level AST nodes."""
    try:
        from tree_sitter_language_pack import get_parser

        parser = get_parser(lang)
    except Exception:
        return []
    source = text.encode("utf-8", errors="replace")
    tree = parser.parse(source)
    blocks: list[tuple[str, str]] = []
    last_byte = 0
    for child in tree.root_node.children:
        if child.type not in _TS_AST_BLOCK_TYPES:
            continue
        if child.start_byte > last_byte:
            preamble = source[last_byte : child.start_byte].decode("utf-8", errors="replace").strip()
            if preamble:
                blocks.append(("module", preamble))
        snippet = source[child.start_byte : child.end_byte].decode("utf-8", errors="replace").strip()
        if snippet:
            blocks.append((_ts_node_symbol_name(child, source), snippet))
        last_byte = child.end_byte
    if last_byte < len(source):
        tail = source[last_byte:].decode("utf-8", errors="replace").strip()
        if tail:
            blocks.append(("module", tail))
    return blocks


def chunk_code(
    text: str,
    file_path: str,
    chunk_size: int = 1200,
    overlap: int = 150,
) -> list[str]:
    """Chunk source code on top-level AST boundaries with file + symbol headers."""
    if not text or not text.strip():
        return []
    suffix = Path(file_path).suffix.lower()
    if suffix == ".py":
        blocks = _python_ast_blocks(text)
    elif suffix in _CODE_EXT_TO_TS:
        blocks = _treesitter_ast_blocks(text, _CODE_EXT_TO_TS[suffix])
    else:
        blocks = []

    if not blocks:
        header = f"# file: {file_path}\n"
        return [f"{header}{c}" for c in chunk_text(text, chunk_size=chunk_size, overlap=overlap)]

    chunks: list[str] = []
    for symbol, body in blocks:
        header = f"# file: {file_path}\n# symbol: {symbol}\n"
        if len(header) + len(body) <= chunk_size:
            chunks.append(f"{header}{body}")
            continue
        sub_budget = max(200, chunk_size - len(header))
        for seg in _chunk_plain_segment(body, chunk_size=sub_budget, overlap=overlap):
            chunks.append(f"{header}{seg}")
    return chunks


class _DenseEmbeddingAdapter:
    """Unified embedding adapter supporting FastEmbed (ONNX) and OpenAI-compatible API."""

    def __init__(
        self,
        config,
        model_name_override: str | None = None,
        dimension_override: int | None = None,
    ):
        self.config = config
        self.api_key = config.embedding_api_key
        self.base_url = config.embedding_base_url
        self.model_name = model_name_override or config.embedding_model_name
        self.dimension = dimension_override or config.embedding_dimension
        self.is_remote = bool(self.api_key or self.base_url)
        _matryoshka_prefixes = (
            "text-embedding-3",
            "nomic-embed",
            "jina-embeddings",
        )
        self.is_matryoshka = (
            self.is_remote
            and any(p in self.model_name for p in _matryoshka_prefixes)
        )

        if self.is_remote:
            from openai import OpenAI

            self.client = OpenAI(
                api_key=self.api_key or "local",
                base_url=self.base_url or None,
            )
            self.model = None
        else:
            from fastembed import TextEmbedding

            self.client = None
            self.model = TextEmbedding(
                model_name=self.model_name,
                threads=config.embedding_threads,
            )

    def embed_passages(
        self, texts: list[str], batch_size: int = 64
    ) -> list[list[float]]:
        if not texts:
            return []
        if self.is_remote and self.client:
            create_kwargs: dict[str, Any] = {"model": self.model_name, "input": texts}
            if self.is_matryoshka and self.dimension:
                create_kwargs["dimensions"] = self.dimension
            res = self.client.embeddings.create(**create_kwargs)
            return [item.embedding for item in res.data]
        raw = list(self.model.passage_embed(texts, batch_size=batch_size))
        return [r.tolist() if hasattr(r, "tolist") else list(r) for r in raw]

    def embed_query(self, text: str) -> list[float]:
        if not text:
            return [0.0] * self.dimension
        if self.is_remote and self.client:
            create_kwargs: dict[str, Any] = {"model": self.model_name, "input": [text]}
            if self.is_matryoshka and self.dimension:
                create_kwargs["dimensions"] = self.dimension
            res = self.client.embeddings.create(**create_kwargs)
            return res.data[0].embedding
        raw = next(iter(self.model.query_embed([text])))
        return raw.tolist() if hasattr(raw, "tolist") else list(raw)

    def encode(
        self,
        texts: str | list[str],
        batch_size: int = 64,
        normalize_embeddings: bool = True,
    ) -> Any:
        import numpy as np

        if isinstance(texts, str):
            vec = self.embed_query(texts)
            arr = np.array(vec, dtype=np.float32)
            if normalize_embeddings:
                norm = np.linalg.norm(arr)
                if norm > 0:
                    arr = arr / norm
            return arr

        if not texts:
            return np.empty((0, self.dimension), dtype=np.float32)

        vectors = self.embed_passages(texts, batch_size=batch_size)
        arr = np.array(vectors, dtype=np.float32)
        if normalize_embeddings and len(arr) > 0:
            norms = np.linalg.norm(arr, axis=1, keepdims=True)
            norms[norms == 0] = 1.0
            arr = arr / norms
        return arr


@lru_cache(maxsize=1)
def get_embedding_model() -> _DenseEmbeddingAdapter:
    """Load model once and cache it."""
    from backend.config import get_config

    config = get_config()
    return _DenseEmbeddingAdapter(config)


@lru_cache(maxsize=1)
def get_code_embedding_model() -> _DenseEmbeddingAdapter:
    """Load optional code-tuned embedding model (falls back to standard model)."""
    from backend.config import get_config

    config = get_config()
    if config.code_embedding_model_name:
        return _DenseEmbeddingAdapter(
            config,
            model_name_override=config.code_embedding_model_name,
            dimension_override=config.code_embedding_dimension,
        )
    return get_embedding_model()


@lru_cache(maxsize=1)
def get_sparse_embedding_model():
    """Load sparse model once and cache it."""
    from fastembed import SparseTextEmbedding

    from backend.config import get_config

    config = get_config()
    model_name = config.sparse_embedding_model_name
    if model_name == "Qdrant/bm25":
        return SparseTextEmbedding(model_name=model_name, disable_stemmer=True)
    return SparseTextEmbedding(model_name=model_name)


def embed_text(text: str) -> list[float]:
    """Embed text using local fastembed ONNX or remote model."""
    if not text:
        from backend.config import get_config

        return [0.0] * get_config().embedding_dimension

    model = get_embedding_model()
    return model.embed_query(text)


def embed_code_text(text: str) -> list[float]:
    """Embed code text using configured code-tuned dense model (or standard fallback)."""
    from backend.config import get_config

    cfg = get_config()
    if not text:
        dim = cfg.code_embedding_dimension if cfg.code_embedding_model_name else cfg.embedding_dimension
        return [0.0] * dim
    return get_code_embedding_model().embed_query(text)


def embed_text_sparse(text: str) -> dict:
    """Embed text using local fastembed sparse model (BM25 or SPLADE)."""
    if not text:
        return {"indices": [], "values": []}

    from backend.config import get_config

    config = get_config()
    prepared_text = (
        _pretokenize_cjk(expand_code_identifiers(text))
        if config.sparse_embedding_model_name == "Qdrant/bm25"
        else text
    )

    model = get_sparse_embedding_model()
    embeddings = list(model.query_embed([prepared_text]))
    if embeddings and len(embeddings) > 0:
        return {
            "indices": embeddings[0].indices.tolist(),
            "values": embeddings[0].values.tolist(),
        }
    return {"indices": [], "values": []}


def chunk_and_embed(
    text: str,
    chunk_size: int = 800,
    chunk_overlap: int = 150,
    batch_size: int = 64,
    file_path: str | None = None,
    use_code_model: bool = False,
) -> list[tuple[str, list[float], dict]]:
    """Chunks text and returns list of (chunk_text, dense_vector, sparse_vector)."""
    if is_code_file(file_path):
        raw_chunks = chunk_code(
            text, file_path=file_path or "", chunk_size=max(chunk_size, 1200), overlap=chunk_overlap
        )
    else:
        raw_chunks = chunk_text(text, chunk_size=chunk_size, overlap=chunk_overlap)
    if not raw_chunks:
        return []

    # Ingestion-time boilerplate & duplicate suppression:
    # Drops verbatim repeating headers, footers, or duplicate paragraphs within the document.
    seen_texts: set[str] = set()
    chunks: list[str] = []
    for c in raw_chunks:
        norm = " ".join(c.strip().split())
        if norm and norm not in seen_texts:
            seen_texts.add(norm)
            chunks.append(c)

    if not chunks:
        return []

    # Batch dense embeddings on marker-free text so <!-- page:N --> never pollutes vectors
    embed_texts = [_PAGE_SPLIT_RE.sub("", c).strip() or c for c in chunks]
    dense_model = get_code_embedding_model() if use_code_model else get_embedding_model()
    dense_vectors = dense_model.embed_passages(embed_texts, batch_size=batch_size)

    # Batch sparse embeddings
    from backend.config import get_config

    config = get_config()
    sparse_model = get_sparse_embedding_model()
    if config.sparse_embedding_model_name == "Qdrant/bm25":
        prepared_chunks = [_pretokenize_cjk(expand_code_identifiers(c)) for c in embed_texts]
    else:
        prepared_chunks = embed_texts

    sparse_raw = list(sparse_model.embed(prepared_chunks, batch_size=batch_size))
    sparse_vectors = [
        {
            "indices": (
                s.indices.tolist() if hasattr(s.indices, "tolist") else list(s.indices)
            ),
            "values": (
                s.values.tolist() if hasattr(s.values, "tolist") else list(s.values)
            ),
        }
        for s in sparse_raw
    ]

    return [
        (chunks[i], dense_vectors[i], sparse_vectors[i]) for i in range(len(chunks))
    ]
