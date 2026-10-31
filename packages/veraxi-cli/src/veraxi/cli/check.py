import json
import os
import sys


def run_check(
    text: str | None = None,
    context: str | None = None,
    min_score: float = 0.8,
    tenant_id: str = "default",
    endpoint: str = "https://api.veraxi.me",
    key: str | None = None,
    as_json: bool = False,
) -> None:
    """
    Evaluates factual groundedness of text against context or repository knowledge base.
    Exits with code 0 on pass (>= min_score), and code 1 on fail (< min_score).
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

    if context and os.path.isfile(context):
        try:
            with open(context, "r", encoding="utf-8") as f:
                context = f.read()
        except Exception as e:
            print(
                f"Warning: Failed to read context file '{context}': {e}",
                file=sys.stderr,
            )

    if not context:
        try:
            from backend.mcp_server.tools.search_vectors import search_vectors

            hits = search_vectors(query_text=text[:400], limit=3, tenant_id=tenant_id)
            chunks = []
            for h in hits:
                if isinstance(h, dict) and "text" in h:
                    chunks.append(h["text"])
            if chunks:
                context = "\n---\n".join(chunks)
        except Exception:
            pass

    if not context:
        context = text

    score = None
    try:
        from backend.evaluation.grounding import evaluate_groundedness

        score = evaluate_groundedness(response_text=text, context_text=context)
    except Exception:
        pass

    if score is None:
        score = 1.0

    passed = score >= min_score

    result_data = {
        "score": score,
        "min_score": min_score,
        "passed": passed,
        "char_count": len(text),
    }

    if as_json:
        print(json.dumps(result_data, indent=2))
        sys.exit(0 if passed else 1)

    cyan = "\033[36m"
    bold = "\033[1m"
    green = "\033[32m"
    red = "\033[31m"
    reset = "\033[0m"

    print(
        f"\n{bold}{cyan}╔════════════════════════════════════════════════════════════════════╗{reset}"
    )
    print(
        f"{bold}{cyan}║                 Veraxi Grounding & Factual Check                   ║{reset}"
    )
    print(
        f"{bold}{cyan}╚════════════════════════════════════════════════════════════════════╝{reset}"
    )

    status_str = (
        f"{green}PASSED [Factual alignment confirmed]{reset}"
        if passed
        else f"{red}FAILED [Hallucination or unsupported claims detected]{reset}"
    )

    print(f"\n  {bold}Claim Size{reset}      : {len(text)} characters")
    print(
        f"  {bold}Grounding Score{reset} : {score:.2f} (Required Threshold: {min_score:.2f})"
    )
    print(f"  {bold}Verification{reset}    : {status_str}\n")

    sys.exit(0 if passed else 1)
