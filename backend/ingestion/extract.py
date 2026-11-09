import json
import logging
from typing import Any

import sentry_sdk
from openai import OpenAI

from backend.config import get_config
from backend.ingestion.entity_resolution import is_clean_entity_name
from backend.prompts import get_extraction_prompt

logger = logging.getLogger(__name__)


def _clean_llm_json_output(output: str) -> str:
    """Removes markdown code blocks if the LLM hallucinated them."""
    output = output.strip()
    if output.startswith("```json"):
        output = output[7:]
    elif output.startswith("```"):
        output = output[3:]

    output = output.removesuffix("```")

    return output.strip()


def _is_valid_entity(ent_type: Any, name: Any, allowed_entities: list[str]) -> bool:
    return (
        ent_type in allowed_entities
        and isinstance(name, str)
        and is_clean_entity_name(name)
    )


def _validate_single_relation(
    rel: dict[str, str],
    entity_name_to_type: dict[str, str],
    allowed_relations: dict,
    allow_cooccurrence: bool = False,
) -> dict[str, str] | None:
    if not isinstance(rel, dict):
        return None

    from_ent = str(rel.get("from_entity", ""))
    to_ent = str(rel.get("to_entity", ""))
    rel_type = str(rel.get("type", ""))

    if not from_ent or not to_ent or not rel_type:
        return None

    if from_ent not in entity_name_to_type or to_ent not in entity_name_to_type:
        return None

    from_type = entity_name_to_type[from_ent]
    to_type = entity_name_to_type[to_ent]

    allowed_types = allowed_relations.get(from_type, {}).get(to_type, [])
    if rel_type in allowed_types or (
        allow_cooccurrence and rel_type == "MENTIONED_WITH"
    ):
        return {"from_entity": from_ent, "to_entity": to_ent, "type": rel_type}
    return None


def _normalize_single_property(value: Any) -> Any | None:
    if value is None:
        return None
    if isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, list) and all(
        isinstance(item, (str, int, float, bool)) for item in value
    ):
        return value
    return None


def _normalize_properties(props: Any) -> dict[str, Any]:
    """
    Normalize properties to Neo4j-safe values.
    Neo4j properties must be primitives or arrays of primitives - no nested maps.
    """
    if not isinstance(props, dict):
        return {}

    normalized = {}
    for key, value in props.items():
        norm_val = _normalize_single_property(value)
        if norm_val is not None:
            normalized[key] = norm_val

    return normalized


def _validate_entities(
    entities: list[dict[str, Any]], allowed_entities: list[str]
) -> tuple[list[dict[str, Any]], dict[str, str]]:
    valid_entities = []
    entity_name_to_type = {}

    for ent in entities:
        if not isinstance(ent, dict):
            continue

        ent_type = str(ent.get("type", ""))
        name = str(ent.get("name", ""))
        props = ent.get("properties", {})
        raw_aliases = ent.get("aliases", [])
        aliases = (
            [
                str(a).strip()
                for a in raw_aliases
                if isinstance(a, str) and is_clean_entity_name(str(a))
            ]
            if isinstance(raw_aliases, list)
            else []
        )

        if _is_valid_entity(ent_type, name, allowed_entities):
            valid_ent: dict[str, Any] = {
                "type": ent_type,
                "name": name,
                "properties": _normalize_properties(props),
            }
            if aliases:
                valid_ent["aliases"] = aliases
            valid_entities.append(valid_ent)
            entity_name_to_type[name] = ent_type
            for alias in aliases:
                entity_name_to_type.setdefault(alias, ent_type)

    return valid_entities, entity_name_to_type


def _validate_relations(
    relations: list[dict[str, str]],
    entity_name_to_type: dict[str, str],
    allowed_relations: dict,
    allow_cooccurrence: bool = False,
) -> list[dict[str, str]]:
    valid_relations = []
    for rel in relations:
        valid_rel = _validate_single_relation(
            rel,
            entity_name_to_type,
            allowed_relations,
            allow_cooccurrence=allow_cooccurrence,
        )
        if valid_rel:
            valid_relations.append(valid_rel)
    return valid_relations


def validate_extraction(
    entities: list[dict[str, Any]],
    relations: list[dict[str, str]],
    schema: dict,
    allow_cooccurrence: bool = False,
) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    """
    Pure-logic validation step that rejects/quarantines any LLM output that doesn't match the schema.
    """
    if not schema:
        raise ValueError("A valid schema must be provided for validation.")
    valid_entities, entity_name_to_type = _validate_entities(
        entities, schema["entities"]
    )
    valid_relations = _validate_relations(
        relations,
        entity_name_to_type,
        schema.get("relations", {}),
        allow_cooccurrence=allow_cooccurrence,
    )
    return valid_entities, valid_relations


def extract_entities_and_relations(
    text: str, schema: dict, model_name: str | None = None
) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    """
    Extract entities and relations using OpenAI API constrained to a dynamic schema.
    """
    if not schema:
        raise ValueError("A valid schema must be provided for extraction.")

    config = get_config()
    llm_args = config.get_llm_client_args()
    llm_args.setdefault("timeout", 10.0)
    client = OpenAI(**llm_args)

    try:
        response = client.chat.completions.create(
            model=model_name or config.llm_model_name,
            messages=[
                {"role": "system", "content": get_extraction_prompt(schema)},
                {"role": "user", "content": f"Text to analyze:\n{text}"},
            ],
            response_format={"type": "json_object"},
            temperature=0.0,
        )

        output = _clean_llm_json_output(response.choices[0].message.content or "")
        data = json.loads(output)

        raw_entities = data.get("entities", [])
        raw_relations = data.get("relations", [])

        from backend.ingestion.entity_resolution import (
            extract_in_text_aliases,
            normalize_name,
            strip_generic_suffix,
        )

        in_text_aliases = extract_in_text_aliases(text)
        if in_text_aliases and isinstance(raw_entities, list):
            for ent in raw_entities:
                if isinstance(ent, dict) and isinstance(ent.get("name"), str):
                    norm_key = strip_generic_suffix(normalize_name(ent["name"]))
                    extra = in_text_aliases.get(norm_key, set())
                    if extra:
                        existing_aliases = ent.get("aliases")
                        if not isinstance(existing_aliases, list):
                            existing_aliases = []
                        merged_aliases = list(
                            dict.fromkeys(
                                [str(a) for a in existing_aliases if isinstance(a, str)]
                                + sorted(extra)
                            )
                        )
                        ent["aliases"] = merged_aliases

        return validate_extraction(raw_entities, raw_relations, schema)
    except Exception as e:
        sentry_sdk.capture_exception(e)
        return [], []


_REL_STOP_PARTS = {
    "at",
    "in",
    "of",
    "to",
    "for",
    "with",
    "by",
    "on",
    "from",
    "as",
    "into",
    "is",
    "has",
}


def _dependency_path_tokens(tok1: Any, tok2: Any) -> list[Any]:
    """Return tokens on the syntactic dependency path between tok1 and tok2."""
    anc1 = [tok1, *list(tok1.ancestors)]
    anc2 = [tok2, *list(tok2.ancestors)]
    anc2_set = set(anc2)
    lca = next((t for t in anc1 if t in anc2_set), None)
    if lca is None:
        return [tok1, tok2]
    path: list[Any] = []
    for t in anc1:
        path.append(t)
        if t == lca:
            break
    for t in anc2:
        if t == lca:
            break
        path.append(t)
    return path


def _is_path_negated(path_tokens: list[Any]) -> bool:
    """Return True if any verb/head on the dependency path has a negation modifier."""
    for tok in path_tokens:
        for child in getattr(tok, "children", []):
            if getattr(child, "dep_", "") == "neg" or getattr(child, "lower_", "") in {
                "not",
                "never",
                "no",
                "neither",
            }:
                return True
    return False


def _match_grounded_schema_relation(
    path_tokens: list[Any], allowed_candidates: list[str]
) -> str | None:
    """Match an allowed schema relation only if a content word shares a lemma/stem on the dependency path."""
    if not allowed_candidates or _is_path_negated(path_tokens):
        return None

    path_lemmas: set[str] = set()
    for tok in path_tokens:
        lemma = getattr(tok, "lemma_", "").lower().strip()
        lower = getattr(tok, "lower_", "").lower().strip()
        if lemma and len(lemma) >= 3:
            path_lemmas.add(lemma)
        if lower and len(lower) >= 3:
            path_lemmas.add(lower)

    for cand in allowed_candidates:
        if cand in ("MENTIONED_WITH", "RELATED_TO", "ASSOCIATED_WITH"):
            continue
        parts = [
            p
            for p in cand.lower().split("_")
            if p and p not in _REL_STOP_PARTS and len(p) >= 3
        ]
        if not parts:
            continue
        for part in parts:
            stem = part[:4] if len(part) >= 5 else part
            if any(
                pl == part
                or (len(stem) >= 4 and pl.startswith(stem))
                or part.startswith(pl[:4])
                for pl in path_lemmas
                if len(pl) >= 4 or pl == part
            ):
                return cand
    return None


def _is_passive_reversed(tok1: Any, tok2: Any, path_tokens: list[Any]) -> bool:
    """Return True if tok1 is the passive patient ('nsubjpass') and tok2 is the 'by' agent."""
    dep1 = getattr(tok1, "dep_", "")
    head2 = getattr(tok2, "head", None)
    head2_dep = getattr(head2, "dep_", "") if head2 is not None else ""
    head2_lower = getattr(head2, "lower_", "") if head2 is not None else ""
    if dep1 in ("nsubjpass", "csubjpass") and (
        head2_dep == "agent" or head2_lower == "by"
    ):
        return True
    return head2_dep == "agent" and any(
        getattr(ch, "dep_", "") in ("auxpass", "nsubjpass")
        for t in path_tokens
        for ch in getattr(t, "children", [])
    )


def _extract_relations_from_sentence(sent, entity_name_to_type, allowed_relations):
    """
    Extract relations from a sentence using spaCy's syntactic dependency tree.
    Emits a specific schema relation ONLY when grounded in the dependency path verbs/lemmas
    without negation; otherwise emits an honest 'MENTIONED_WITH' co-occurrence edge.
    """
    relations = []
    valid_spans = [ent for ent in sent.ents if ent.text.strip() in entity_name_to_type]

    if len(valid_spans) < 2:
        return relations

    seen_pairs: set[tuple[str, str, str]] = set()
    for i in range(len(valid_spans)):
        for j in range(i + 1, len(valid_spans)):
            span1 = valid_spans[i]
            span2 = valid_spans[j]
            e1 = span1.text.strip()
            e2 = span2.text.strip()
            if e1 == e2:
                continue

            t1 = entity_name_to_type.get(e1)
            t2 = entity_name_to_type.get(e2)
            path_tokens = _dependency_path_tokens(span1.root, span2.root)

            # Respect passive voice directionality (e.g., "Figma was acquired by Adobe" -> Adobe ACQUIRED Figma)
            if _is_passive_reversed(span1.root, span2.root, path_tokens):
                subj_ent, subj_type = e2, t2
                obj_ent, obj_type = e1, t1
            else:
                subj_ent, subj_type = e1, t1
                obj_ent, obj_type = e2, t2

            allowed_fwd = allowed_relations.get(subj_type, {}).get(obj_type, [])
            matched_fwd = _match_grounded_schema_relation(path_tokens, allowed_fwd)
            if matched_fwd:
                key = (subj_ent, obj_ent, matched_fwd)
                if key not in seen_pairs:
                    seen_pairs.add(key)
                    relations.append(
                        {
                            "from_entity": subj_ent,
                            "to_entity": obj_ent,
                            "type": matched_fwd,
                        }
                    )
                continue

            allowed_rev = allowed_relations.get(obj_type, {}).get(subj_type, [])
            matched_rev = _match_grounded_schema_relation(path_tokens, allowed_rev)
            if matched_rev:
                key = (obj_ent, subj_ent, matched_rev)
                if key not in seen_pairs:
                    seen_pairs.add(key)
                    relations.append(
                        {
                            "from_entity": obj_ent,
                            "to_entity": subj_ent,
                            "type": matched_rev,
                        }
                    )
                continue

            # Honest fallback: untyped co-occurrence (never guess allowed_t1_t2[0])
            co_key = (e1, e2, "MENTIONED_WITH")
            if co_key not in seen_pairs:
                seen_pairs.add(co_key)
                relations.append(
                    {"from_entity": e1, "to_entity": e2, "type": "MENTIONED_WITH"}
                )

    return relations


_SPACY_MODEL_MAP = {
    "en": "en_core_web_sm",
    "es": "es_core_news_sm",
    "fr": "fr_core_news_sm",
    "de": "de_core_news_sm",
    "pt": "pt_core_news_sm",
    "it": "it_core_news_sm",
    "nl": "nl_core_news_sm",
    "zh": "zh_core_web_sm",
    "ja": "ja_core_news_sm",
    "ko": "ko_core_news_sm",
    "ru": "ru_core_news_sm",
    "pl": "pl_core_news_sm",
    "multi": "xx_ent_wiki_sm",
    "xx": "xx_ent_wiki_sm",
}


def _load_spacy_model(language: str):
    """Load the requested spaCy model, falling back to multilingual xx_ent_wiki_sm or blank pipeline."""
    import spacy

    lang_key = (language or "xx").lower().split("-")[0]
    candidates = [
        _SPACY_MODEL_MAP.get(lang_key, "xx_ent_wiki_sm"),
        "xx_ent_wiki_sm",
        "en_core_web_sm",
    ]
    nlp = None
    for candidate in dict.fromkeys(candidates):
        try:
            nlp = spacy.load(candidate)
            break
        except OSError:
            try:
                import spacy.cli

                spacy.cli.download(candidate)
                nlp = spacy.load(candidate)
                break
            except (Exception, SystemExit) as err:
                logger.warning(
                    f"Could not load or download spaCy model {candidate}: {err}"
                )

    if nlp is None:
        nlp = spacy.blank("xx")

    if (
        "parser" not in nlp.pipe_names
        and "senter" not in nlp.pipe_names
        and "sentencizer" not in nlp.pipe_names
    ):
        nlp.add_pipe(
            "sentencizer",
            config={"punct_chars": [".", "!", "?", "。", "！", "？", "\n"]},
        )
    return nlp


def extract_entities_and_relations_fast(
    text: str, schema: dict, language: str = "en", custom_stop_words: list | None = None
) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    """
    Extract entities and relations using spaCy (FastGraphRAG NLP fallback) instead of an LLM.
    This provides ~90/10 ratio extraction speeds, sacrificing deep reasoning for speed.
    """
    nlp = _load_spacy_model(language)

    # Build request-local effective stop words without mutating global nlp.Defaults.stop_words
    effective_stop_words = set(nlp.Defaults.stop_words)
    if custom_stop_words:
        for word in custom_stop_words:
            effective_stop_words.add(word.lower())

    # Ensure large texts (such as whole books) do not trigger spaCy max_length errors
    nlp.max_length = max(len(text) + 50000, 5000000)

    doc = nlp(text)

    entities = []
    entity_name_to_type = {}

    from backend.ingestion.entity_resolution import (
        extract_in_text_aliases,
        normalize_name,
        strip_generic_suffix,
    )

    in_text_aliases = extract_in_text_aliases(text)

    # SpaCy to Schema Type Mapping
    allowed_types = set(schema.get("entities", []))
    spacy_to_schema = {
        "PERSON": "Person",
        "PER": "Person",
        "ORG": "Organization",
        "GPE": "Location",
        "LOC": "Location",
        "FAC": "Location",
        "DATE": "Date",
        "EVENT": "Event",
        "WORK_OF_ART": "Concept",
        "MISC": "Concept",
    }

    # Extract Entities
    for ent in doc.ents:
        # Check if the root of the entity is a stop word or custom stop word
        ent_text_lower = ent.text.lower()
        root_text_lower = ent.root.text.lower()
        if (
            ent.root.is_stop
            or root_text_lower in effective_stop_words
            or ent_text_lower in effective_stop_words
        ):
            continue

        name = ent.text.strip()
        if not is_clean_entity_name(name):
            continue

        # Try to map to the dynamic schema, otherwise use the spaCy label
        mapped_type = spacy_to_schema.get(ent.label_, ent.label_.capitalize())

        # If schema is strict, we should ideally coerce it.
        # For fast NLP, we coerce to a generic 'Entity' if it doesn't match the schema,
        # or just pass it through if it's close.
        if allowed_types and mapped_type not in allowed_types:
            # Fallback to the first allowed type, or generic "Entity"
            mapped_type = next(iter(allowed_types)) if allowed_types else "Entity"

        norm_key = strip_generic_suffix(normalize_name(name))
        discovered_aliases = sorted(in_text_aliases.get(norm_key, set()))
        ent_dict: dict[str, Any] = {"type": mapped_type, "name": name, "properties": {}}
        if discovered_aliases:
            ent_dict["aliases"] = discovered_aliases
        entities.append(ent_dict)
        entity_name_to_type[name] = mapped_type

    # Extract Relationships based on sentence co-occurrence
    relations = []
    allowed_relations = schema.get("relations", {})

    for sent in doc.sents:
        relations.extend(
            _extract_relations_from_sentence(
                sent, entity_name_to_type, allowed_relations
            )
        )

    # We run it through validate_extraction allowing co-occurrence edges
    return validate_extraction(entities, relations, schema, allow_cooccurrence=True)
