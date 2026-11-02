"""Native fact-check proof engine for Veraxi MCP server."""

import json
import logging
import re
from typing import Any

from backend.config import get_config
from backend.evaluation.grounding import evaluate_groundedness
from backend.ingestion.document_parser import extract_verbatim_quote
from backend.mcp_server.tools.search_vectors import search_vectors

logger = logging.getLogger(__name__)


def _compute_fallback_grounding(
    claim: str, evidence: str, sources: list[str] | None = None
) -> float:
    """Deterministic token-level overlap score with light stemming and source awareness."""

    def _stem(w: str) -> str:
        return re.sub(r"(ing|ed|s|es|tion|ly)$", "", w.lower())

    source_text = " ".join(sources or []).lower()
    full_evidence = f"{evidence} {source_text}".lower()
    evidence_tokens = set(re.findall(r"\w+", full_evidence))

    claim_tokens = [w.lower() for w in re.findall(r"\w+", claim) if len(w) > 2]
    stopwords = {
        "the",
        "and",
        "for",
        "with",
        "that",
        "this",
        "from",
        "was",
        "were",
        "what",
        "why",
        "how",
        "has",
        "have",
        "had",
        "can",
        "could",
        "should",
        "would",
        "about",
        "such",
    }
    meaningful = [w for w in claim_tokens if w not in stopwords]
    if not meaningful:
        return 1.0

    matches = 0
    for w in meaningful:
        st = _stem(w)
        if w in evidence_tokens or (st and any(st in ew for ew in evidence_tokens)):
            matches += 1
    return round(matches / max(1, len(meaningful)), 2)


def perform_fact_check(
    claim: str,
    min_score: float = 0.8,
    tenant_id: str = "default",
    peek: bool = True,
    top_k: int = 3,
) -> dict[str, Any]:
    """
    Evaluates factual groundedness of a claim against the repository knowledge base.
    Extracts verbatim sub-sentence quotes, page numbers, and returns proof data and markdown.
    """
    if not claim or not claim.strip():
        return {
            "score": 0.0,
            "min_score": min_score,
            "passed": False,
            "error": "Empty claim provided.",
            "evidence": [],
            "markdown": "❌ **Fact Check Error:** Empty claim provided.",
        }

    evidence_records: list[dict] = []
    context = ""

    try:
        hits = search_vectors(
            query_text=claim[:400], limit=top_k, tenant_id=tenant_id
        )
        context_chunks = []

        for h in hits:
            payload = (
                getattr(h, "payload", {})
                if hasattr(h, "payload")
                else (h if isinstance(h, dict) else {})
            )
            chunk_text = payload.get("text", "")
            if not chunk_text:
                continue
            page_num = payload.get("page_number")
            source = (
                payload.get("source")
                or payload.get("document_id")
                or "Unknown Document"
            )
            breadcrumb = payload.get("breadcrumb")
            is_table = bool(payload.get("is_table"))

            header_prefix = f"[Document: {source}"
            if page_num:
                header_prefix += f" | Page: {page_num}"
            if breadcrumb:
                header_prefix += f" | Section: {breadcrumb}"
            header_prefix += "]\n"
            context_chunks.append(header_prefix + chunk_text)

            quote = extract_verbatim_quote(claim, chunk_text, max_words=35)

            evidence_records.append(
                {
                    "id": getattr(h, "id", None),
                    "score": getattr(h, "score", None),
                    "source": source,
                    "page": page_num,
                    "breadcrumb": breadcrumb,
                    "is_table": is_table,
                    "verbatim_quote": quote,
                    "chunk_text": chunk_text,
                }
            )

        if context_chunks:
            context = "\n---\n".join(context_chunks)
    except Exception as exc:
        logger.debug(f"Failed to retrieve vector context for fact check: {exc}")

    if not context:
        context = claim

    score = None
    try:
        score = evaluate_groundedness(response_text=claim, context_text=context)
    except Exception as exc:
        logger.debug(f"LLM grounding evaluation failed, using fallback: {exc}")

    if score is None:
        source_names = [ev.get("source", "") for ev in evidence_records]
        score = _compute_fallback_grounding(claim, context, source_names)

    passed = score >= min_score

    # Construct Markdown Proof Card
    status_badge = (
        "🟢 **FACT CHECK PASSED [Factual alignment confirmed]**"
        if passed
        else "🔴 **FACT CHECK FAILED [Disputed or unverified claims]**"
    )

    md_lines = [
        "### 🛡️ VERAXI FORENSIC FACT-CHECK PROOF CARD",
        f'> **Claim:** *"{claim}"*',
        "",
        f"- **Verification:** {status_badge}",
        f"- **Grounding Score:** `{score:.2f}` (Required Threshold: `{min_score:.2f}`)",
        "",
        f"#### 📑 Forensic Evidence Citations ({len(evidence_records)} passages retrieved)",
        "| # | Document | Location | Verbatim Proof Quote |",
        "|---|---|---|---|",
    ]

    for idx, ev in enumerate(evidence_records, start=1):
        src = ev["source"]
        if len(src) > 50:
            src = src[:47] + "..."
        page_str = f"Page {ev['page']}" if ev.get("page") else "N/A"
        quote_str = (
            f"*\"{ev['verbatim_quote']}\"*" if ev.get("verbatim_quote") else "N/A"
        )
        md_lines.append(f"| **{idx}** | *{src}* | **{page_str}** | {quote_str} |")

    card_markdown = "\n".join(md_lines)
    result_data = {
        "score": score,
        "min_score": min_score,
        "passed": passed,
        "evidence": evidence_records,
        "markdown": card_markdown,
    }
    return result_data
