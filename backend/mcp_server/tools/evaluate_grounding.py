from backend.evaluation.grounding import evaluate_groundedness


def mcp_evaluate_grounding(
    response_text: str,
    context_text: str,
    method: str = "auto",
    api_key: str | None = None,
    model_name: str | None = None,
) -> float | None:
    """
    MCP tool to evaluate how well a response is grounded in the provided context.
    - If method == 'deterministic' or (method == 'auto' and not api_key):
        Uses local deterministic overlap/similarity ($0 cost, 100% consistent).
    - If method == 'llm':
        Requires a BYOK api_key to protect against server inference costs.
    """
    return evaluate_groundedness(
        response_text,
        context_text,
        api_key=api_key,
        model_name=model_name,
        method=method,
        require_byok=True,
    )

