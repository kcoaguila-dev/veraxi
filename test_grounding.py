from backend.evaluation.grounding import evaluate_groundedness
import json
import logging

logging.basicConfig(level=logging.INFO)

context = "The company Veraxi was founded in 2026. It specializes in AI agents."
response_good = "Veraxi is a company that focuses on AI agents and was founded in 2026."
response_bad = "Veraxi was founded in 2025 and builds physical robots."

print("Testing Good Response...")
score_good = evaluate_groundedness(response_good, context)
print(f"Good Response Score: {score_good}")

print("\nTesting Bad Response...")
score_bad = evaluate_groundedness(response_bad, context)
print(f"Bad Response Score: {score_bad}")
