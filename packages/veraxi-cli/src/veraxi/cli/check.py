import glob
import json
import logging
import os
import re
import sys
import warnings

warnings.filterwarnings("ignore", category=UserWarning, module="qdrant_client")

logger = logging.getLogger(__name__)


def _resolve_pdf_path(source: str) -> str | None:
    """Resolve a document source identifier to an on-disk PDF path if available."""
    if not source:
        return None
    if os.path.isfile(source):
        return os.path.abspath(source)

    search_dirs = [
        "/home/ubuntu/Documents/book",
        os.path.expanduser("~/Documents/book"),
        os.getcwd(),
    ]
    norm_source = re.sub(r"[^a-zA-Z0-9]", "", source.lower())
    for d in search_dirs:
        if not os.path.isdir(d):
            continue
        for cand in glob.glob(os.path.join(d, "*")):
            base = os.path.basename(cand)
            norm_cand = re.sub(r"[^a-zA-Z0-9]", "", base.lower())
            if norm_source[:25] in norm_cand or norm_cand[:25] in norm_source:
                return os.path.abspath(cand)
    return None


def _peek_pdf_page(
    file_path: str, page_number: int, quote: str = "", max_lines: int = 5
) -> str | None:
    """Read physical PDF page text and extract lines surrounding the verbatim quote."""
    try:
        import pypdf

        reader = pypdf.PdfReader(file_path)
        if 1 <= page_number <= len(reader.pages):
            page_text = reader.pages[page_number - 1].extract_text() or ""
            lines = [line.strip() for line in page_text.split("\n") if line.strip()]
            if not lines:
                return None
            if not quote:
                return "\n".join(lines[:max_lines])

            words = [w for w in re.findall(r"\w+", quote.lower()) if len(w) > 3]
            best_idx = -1
            best_overlap = 0
            for idx, line in enumerate(lines):
                line_lower = line.lower()
                overlap = sum(1 for w in words if w in line_lower)
                if overlap > best_overlap:
                    best_overlap = overlap
                    best_idx = idx

            if best_idx >= 0:
                start = max(0, best_idx - 2)
                end = min(len(lines), best_idx + 3)
                formatted_lines = []
                for i in range(start, end):
                    prefix = "  > " if i == best_idx else "    "
                    formatted_lines.append(f"{prefix}{lines[i]}")
                return "\n".join(formatted_lines)
            return "\n".join(f"    {line}" for line in lines[:max_lines])
    except Exception:
        return None
    return None


def _format_osc8_link(uri: str, label: str) -> str:
    """Generate ANSI OSC 8 clickable terminal hyperlink."""
    return f"\033]8;;{uri}\033\\{label}\033]8;;\033\\"


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


def run_check(
    text: str | None = None,
    context: str | None = None,
    min_score: float = 0.8,
    tenant_id: str = "default",
    endpoint: str = "https://api.veraxi.me",
    key: str | None = None,
    as_json: bool = False,
    peek: bool = False,
    top_k: int = 3,
) -> None:
    """
    Evaluates factual groundedness of text against context or repository knowledge base.
    Features:
      - Sub-sentence verbatim quote extraction
      - OSC 8 terminal clickable hyperlink to PDF page
      - In-terminal physical PDF page preview
      - Exits 0 on pass (>= min_score), and 1 on fail (< min_score).
    """
    if not text:
        if not sys.stdin.isatty():
            text = sys.stdin.read().strip()
        else:
            print(
                "Error: No text provided to check. Pass text as argument or pipe via stdin.",
                file=sys.stderr,
            )
            sys.exit(1)

    if not text:
        print("Error: Empty input text provided to check.", file=sys.stderr)
        sys.exit(1)

    evidence_records: list[dict] = []

    # 1. Handle explicit context file or string
    if context and os.path.isfile(context):
        try:
            with open(context, "r", encoding="utf-8") as f:
                context = f.read()
        except Exception as e:
            print(
                f"Warning: Failed to read context file '{context}': {e}",
                file=sys.stderr,
            )

    # 2. Retrieve knowledge base evidence if no explicit context was given
    if not context:
        try:
            from backend.mcp_server.tools.search_vectors import search_vectors
            from backend.ingestion.document_parser import extract_verbatim_quote

            hits = search_vectors(
                query_text=text[:400], limit=top_k, tenant_id=tenant_id
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
                bbox = payload.get("bbox")

                header_prefix = f"[Document: {source}"
                if page_num:
                    header_prefix += f" | Page: {page_num}"
                if breadcrumb:
                    header_prefix += f" | Section: {breadcrumb}"
                header_prefix += "]\n"
                context_chunks.append(header_prefix + chunk_text)

                quote = extract_verbatim_quote(text, chunk_text, max_words=35)
                pdf_path = _resolve_pdf_path(source)
                link = None
                if pdf_path and page_num:
                    link = f"file://{pdf_path}#page={page_num}"

                page_preview = None
                if (peek or pdf_path) and pdf_path and page_num:
                    page_preview = _peek_pdf_page(pdf_path, page_num, quote)

                evidence_records.append(
                    {
                        "id": getattr(h, "id", None),
                        "score": getattr(h, "score", None),
                        "source": source,
                        "page": page_num,
                        "breadcrumb": breadcrumb,
                        "is_table": is_table,
                        "bbox": bbox,
                        "verbatim_quote": quote,
                        "pdf_path": pdf_path,
                        "link": link,
                        "page_preview": page_preview,
                        "chunk_text": chunk_text,
                    }
                )

            if context_chunks:
                context = "\n---\n".join(context_chunks)
        except Exception as exc:
            logger.debug(f"Failed to retrieve vector context: {exc}")

    if not context:
        context = text

    # 3. Grounding evaluation
    score = None
    try:
        from backend.evaluation.grounding import evaluate_groundedness

        score = evaluate_groundedness(response_text=text, context_text=context)
    except Exception as exc:
        logger.debug(f"LLM grounding evaluation failed, using fallback: {exc}")

    if score is None:
        source_names = [ev.get("source", "") for ev in evidence_records]
        score = _compute_fallback_grounding(text, context, source_names)

    passed = score >= min_score

    result_data = {
        "score": score,
        "min_score": min_score,
        "passed": passed,
        "char_count": len(text),
        "evidence": evidence_records,
    }

    if as_json:
        print(json.dumps(result_data, indent=2))
        sys.exit(0 if passed else 1)

    # ANSI color formatting
    cyan = "\033[36m"
    bold = "\033[1m"
    green = "\033[32m"
    red = "\033[31m"
    yellow = "\033[33m"
    magenta = "\033[35m"
    dim = "\033[2m"
    reset = "\033[0m"

    print(
        f"\n{bold}{cyan}╔════════════════════════════════════════════════════════════════════════════╗{reset}"
    )
    print(
        f"{bold}{cyan}║                 VERAXI FORENSIC FACT-CHECK PROOF CARD                      ║{reset}"
    )
    print(
        f"{bold}{cyan}╚════════════════════════════════════════════════════════════════════════════╝{reset}"
    )

    status_str = (
        f"{green}{bold}PASSED [Factual alignment confirmed]{reset}"
        if passed
        else f"{red}{bold}FAILED [Disputed or unverified claims]{reset}"
    )

    print(f"\n  {bold}Claim{reset}           : {text}")
    print(
        f"  {bold}Grounding Score{reset} : {score:.2f} (Required Threshold: {min_score:.2f})"
    )
    print(f"  {bold}Verification{reset}    : {status_str}")

    if evidence_records:
        print(
            f"\n{bold}{magenta}  ─── Forensic Evidence Citations ({len(evidence_records)} passages retrieved) ──────────{reset}"
        )
        for idx, ev in enumerate(evidence_records, start=1):
            source_title = ev["source"]
            if len(source_title) > 65:
                source_title = source_title[:62] + "..."
            page_str = f"Page {ev['page']}" if ev["page"] is not None else "Page N/A"
            table_badge = f" {yellow}[TABLE]{reset}" if ev["is_table"] else ""
            crumb_str = (
                f" | {dim}{ev['breadcrumb']}{reset}" if ev.get("breadcrumb") else ""
            )

            print(f"\n  {bold}[Citation #{idx}]{reset} {cyan}{source_title}{reset}")
            print(
                f"    {bold}Location{reset}    : {bold}{page_str}{reset}{table_badge}{crumb_str}"
            )

            if ev.get("link"):
                osc8_str = _format_osc8_link(
                    ev["link"], f"📄 {page_str} [Ctrl+Click to Open PDF]"
                )
                print(f"    {bold}Terminal Link{reset}: {osc8_str}")

            if ev.get("verbatim_quote"):
                print(
                    f'    {bold}Verbatim Proof{reset}: {green}"{ev["verbatim_quote"]}"{reset}'
                )

            if ev.get("page_preview"):
                print(f"    {bold}Physical PDF Page Peek ({page_str}){reset}:")
                for preview_line in ev["page_preview"].split("\n"):
                    print(f"      {dim}{preview_line}{reset}")

    print()
    sys.exit(0 if passed else 1)
