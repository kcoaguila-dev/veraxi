"""Typed evaluation dataset for evidence-first retrieval ablations.

Defines the case schema used by the ablation runner: every case carries a
``query_type`` (``lookup``, ``multi_hop`` or ``global``), the query text,
the ids of the documents considered relevant, and optional expected-answer /
grounding information.

The JSON loader validates strictly and fails closed: unknown query types,
missing fields, wrong field types, duplicate case ids and duplicate relevant
doc ids are all rejected with :class:`DatasetValidationError` rather than
being silently coerced or dropped.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

QUERY_TYPES: tuple[str, ...] = ("lookup", "multi_hop", "global")

_REQUIRED_FIELDS = ("id", "query_type", "query", "relevant_doc_ids")
_OPTIONAL_FIELDS = ("expected_answer", "grounding_doc_ids", "notes")
_KNOWN_FIELDS = frozenset(_REQUIRED_FIELDS + _OPTIONAL_FIELDS)


class DatasetValidationError(ValueError):
    """Raised when a typed dataset file fails strict validation."""


@dataclass(frozen=True)
class EvalCase:
    """One typed evaluation case."""

    id: str
    query_type: str
    query: str
    relevant_doc_ids: tuple[str, ...]
    expected_answer: str | None = None
    grounding_doc_ids: tuple[str, ...] = ()
    notes: str | None = None


@dataclass(frozen=True)
class TypedDataset:
    """A validated collection of evaluation cases."""

    cases: tuple[EvalCase, ...]
    name: str = "typed-dataset"

    def by_type(self, query_type: str) -> tuple[EvalCase, ...]:
        return tuple(case for case in self.cases if case.query_type == query_type)

    def query_types_present(self) -> tuple[str, ...]:
        return tuple(t for t in QUERY_TYPES if self.by_type(t))


def _fail(message: str) -> DatasetValidationError:
    return DatasetValidationError(message)


def _require_str(raw: dict[str, Any], field_name: str, where: str) -> str:
    value = raw.get(field_name)
    if not isinstance(value, str) or not value.strip():
        raise _fail(f"{where}: field '{field_name}' must be a non-empty string")
    return value


def _parse_doc_ids(raw: dict[str, Any], field_name: str, where: str) -> tuple[str, ...]:
    value = raw.get(field_name)
    if not isinstance(value, list) or not value:
        raise _fail(
            f"{where}: field '{field_name}' must be a non-empty list of strings"
        )
    for item in value:
        if not isinstance(item, str) or not item.strip():
            raise _fail(
                f"{where}: field '{field_name}' must contain non-empty strings only"
            )
    if len(set(value)) != len(value):
        raise _fail(f"{where}: field '{field_name}' contains duplicate doc ids")
    return tuple(value)


def _parse_case(raw: Any, index: int) -> EvalCase:
    where = f"case at index {index}"
    if not isinstance(raw, dict):
        raise _fail(f"{where}: each case must be a JSON object")
    unknown = sorted(set(raw) - _KNOWN_FIELDS)
    if unknown:
        raise _fail(f"{where}: unknown field(s): {', '.join(unknown)}")
    for field_name in _REQUIRED_FIELDS:
        if field_name not in raw:
            raise _fail(f"{where}: missing required field '{field_name}'")

    case_id = _require_str(raw, "id", where)
    where = f"case '{case_id}'"
    query_type = _require_str(raw, "query_type", where)
    if query_type not in QUERY_TYPES:
        raise _fail(
            f"{where}: unknown query_type '{query_type}' "
            f"(expected one of: {', '.join(QUERY_TYPES)})"
        )
    query = _require_str(raw, "query", where)
    relevant = _parse_doc_ids(raw, "relevant_doc_ids", where)

    expected_answer = raw.get("expected_answer")
    if expected_answer is not None and not isinstance(expected_answer, str):
        raise _fail(f"{where}: field 'expected_answer' must be a string when present")
    notes = raw.get("notes")
    if notes is not None and not isinstance(notes, str):
        raise _fail(f"{where}: field 'notes' must be a string when present")
    grounding: tuple[str, ...] = ()
    if "grounding_doc_ids" in raw:
        grounding = _parse_doc_ids(raw, "grounding_doc_ids", where)

    return EvalCase(
        id=case_id,
        query_type=query_type,
        query=query,
        relevant_doc_ids=relevant,
        expected_answer=expected_answer,
        grounding_doc_ids=grounding,
        notes=notes,
    )


def parse_dataset(data: Any, *, name: str = "typed-dataset") -> TypedDataset:
    """Validate already-parsed JSON data and build a :class:`TypedDataset`."""
    if isinstance(data, dict):
        cases_raw = data.get("cases")
        if cases_raw is None:
            raise _fail("dataset object must contain a 'cases' list")
        dataset_name = data.get("name", name)
        if not isinstance(dataset_name, str) or not dataset_name.strip():
            raise _fail("dataset 'name' must be a non-empty string when present")
        name = dataset_name
    elif isinstance(data, list):
        cases_raw = data
    else:
        raise _fail(
            "dataset must be a JSON object with 'cases' or a JSON list of cases"
        )

    if not isinstance(cases_raw, list) or not cases_raw:
        raise _fail("dataset 'cases' must be a non-empty list")

    cases = tuple(_parse_case(raw, index) for index, raw in enumerate(cases_raw))
    seen_ids: set[str] = set()
    for case in cases:
        if case.id in seen_ids:
            raise _fail(f"duplicate case id '{case.id}'")
        seen_ids.add(case.id)
    return TypedDataset(cases=cases, name=name)


def load_dataset(path: str | Path) -> TypedDataset:
    """Load and strictly validate a typed dataset JSON file."""
    dataset_path = Path(path)
    try:
        text = dataset_path.read_text(encoding="utf-8")
    except OSError as exc:
        raise _fail(f"cannot read dataset file {dataset_path}: {exc}") from exc
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise _fail(f"dataset file {dataset_path} is not valid JSON: {exc}") from exc
    return parse_dataset(data, name=dataset_path.stem)


__all__ = [
    "QUERY_TYPES",
    "DatasetValidationError",
    "EvalCase",
    "TypedDataset",
    "load_dataset",
    "parse_dataset",
]
