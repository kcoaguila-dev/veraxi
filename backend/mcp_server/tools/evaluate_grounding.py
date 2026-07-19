from backend.evaluation.grounding import evaluate_groundedness

def mcp_evaluate_grounding(response_text: str, context_text: str) -> float:
    """
    MCP tool to evaluate how well a response is grounded in the provided context.
    """
    return evaluate_groundedness(response_text, context_text)
