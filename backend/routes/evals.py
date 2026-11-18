"""Evidence-evals ablation endpoint (Evidence-First GUI Phase 4).

Follows the ``routes/usage.py`` registration pattern. The runner is
``backend.evaluation.ablation.run_ablation`` fed by the recorded-
rankings retriever from ``backend.evaluation.run_typed_ablation`` —
the exact input shapes that CLI accepts:

* ``dataset``: a typed-dataset object ``{"name": ..., "cases":
  [...]}`` (or ``cases`` at the top level of the request body), each
  case ``{"id", "query_type", "query", "relevant_doc_ids", ...}``
  validated strictly by ``typed_dataset.parse_dataset``;
* ``rankings``: ``{config_name: {query_text: entry}}`` where an
  entry is either a bare list of ranked doc ids or
  ``{"ranked_doc_ids": [...], "grounding_score": 0.8}``.

The response is ``evaluation.report.results_to_dict``: per
configuration (``vector_only`` / ``hybrid_no_graph`` /
``hybrid_with_graph``), overall and per-query-type ``recall_at_k``,
``hit_rate`` and ``grounding_score``. Grounding is null when the
rankings carry no grounding score — it is reported as absent,
never invented. There is no saved-benchmark store in the backend;
the caller supplies dataset + rankings with every run.
"""

import logging

import sentry_sdk
from fastapi import Depends, HTTPException
from pydantic import BaseModel

from backend.evaluation.ablation import run_ablation
from backend.evaluation.report import results_to_dict
from backend.evaluation.run_typed_ablation import RecordedRankingsRetriever
from backend.evaluation.typed_dataset import DatasetValidationError, parse_dataset

logger = logging.getLogger(__name__)


class AblationRequest(BaseModel):
    dataset: dict | None = None
    cases: list[dict] | None = None
    rankings: dict
    k: int = 5


def register_eval_routes(app_router, get_tenant_id, _get_supabase=None, config=None):
    """Register the evidence-evals routes."""

    @app_router.post("/api/v1/evals/ablation")
    async def run_eval_ablation(
        payload: AblationRequest,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Run the typed ablation over caller-supplied rankings."""
        raw_dataset = payload.dataset
        if raw_dataset is None and payload.cases is not None:
            raw_dataset = {"cases": payload.cases}
        if raw_dataset is None:
            raise HTTPException(
                status_code=400,
                detail="Provide a 'dataset' object or a 'cases' list",
            )
        try:
            dataset = parse_dataset(raw_dataset)
        except DatasetValidationError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e
        if not isinstance(payload.rankings, dict) or not payload.rankings:
            raise HTTPException(
                status_code=400, detail="Provide a non-empty 'rankings' object"
            )
        try:
            results = run_ablation(
                dataset,
                RecordedRankingsRetriever(payload.rankings),
                k=payload.k,
            )
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=500, detail="Failed to run ablation"
            ) from e
        return results_to_dict(results)
