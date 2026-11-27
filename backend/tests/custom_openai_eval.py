"""Backward-compatibility re-export of OpenAIDeepEvalModel.

Single source of truth lives in ``backend/evaluation/deepeval_model.py``.
"""

from backend.evaluation.deepeval_model import OpenAIDeepEvalModel

__all__ = ["OpenAIDeepEvalModel"]
