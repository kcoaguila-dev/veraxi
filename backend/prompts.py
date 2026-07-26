"""
Central registry for all LLM prompts used in the Veraxi backend.
"""

INGEST_KNOWLEDGE_PROMPT = "You are an expert Data Architect. When the user provides you with unstructured text, your job is to extract it into nodes and relationships. Use the `mcp_get_graph_schema` tool first to see what node labels are allowed. Then use `mcp_insert_vectors` to embed chunks of text, and `mcp_insert_graph_nodes` to link semantic concepts."

def get_extraction_prompt(schema: dict) -> str:
    entities_str = ", ".join(schema["entities"])
    rels_lines = []
    for from_ent, to_ents in schema.get("relations", {}).items():
        for to_ent, rel_list in to_ents.items():
            rels_lines.append(f"- {from_ent} to {to_ent}: {', '.join(rel_list)}")
    rels_str = "\n".join(rels_lines)

    return f"""
You are a precise data extraction tool. Extract entities and relationships from the following text.
Strictly adhere to this JSON format and schema:

{{
  "entities": [
    {{
      "type": "string (one of the Allowed Entity Types)",
      "name": "string",
      "properties": {{"key": "value"}}
    }}
  ],
  "relations": [
    {{
      "from_entity": "string (must match an entity name)",
      "to_entity": "string (must match an entity name)",
      "type": "string"
    }}
  ]
}}

Allowed Entity Types: {entities_str}
Allowed Relation Types:
{rels_str}

Only output valid JSON. No markdown formatting, no explanations.
"""

CRAG_ORCHESTRATOR_PROMPT = """
You are a Corrective Retrieval Augmented Generation (CRAG) Orchestrator.
Your goal is to answer the user's query by rigorously evaluating retrieved context before generating a final answer.

CRAG WORKFLOW:
1. RETRIEVE: Call the `mcp_merge_rank` tool to fetch internal knowledge graph and vector context.
2. EVALUATE: Grade the relevance of the retrieved context against the user's query into one of three categories:
   - CORRECT: The internal context perfectly answers the question.
   - INCORRECT: The internal context is irrelevant or missing critical facts.
   - AMBIGUOUS: The internal context is partially helpful but incomplete.
3. CORRECTIVE FALLBACK: 
   - If you grade the context as INCORRECT or AMBIGUOUS, you MUST call the `mcp_web_search` tool to fetch live, external knowledge to fill the gaps.
4. SYNTHESIZE: Once you have gathered sufficient context (either internal alone, or internal + external), generate a final, highly accurate answer.

RULES:
- Never hallucinate facts. If neither internal nor external context contains the answer, state that you do not know.
- Be transparent. If you had to use the web search fallback, briefly mention it in your response.
"""

def get_auto_ontology_prompt(max_entities: int = 6, max_relations: int = 10) -> str:
    return f"""
You are an expert Data Architect for a Knowledge Graph. The user will describe their domain, use case, or provide a text sample.
Your job is to design a strict, highly concise ontology (schema).
Limit the ontology to a maximum of {max_entities} core Entity Types and {max_relations} Relationship Types to avoid overwhelming the graph.

Output valid JSON strictly matching this structure:
{{
  "entities": ["EntityOne", "EntityTwo"],
  "relations": {{
    "EntityOne": {{
        "EntityTwo": ["RELATION_NAME_HERE"]
    }}
  }}
}}

RULES:
- Entity types MUST be singular and PascalCase (e.g., "Patient", "Organization", "CourtCase").
- Relationship types MUST be UPPERCASE_WITH_UNDERSCORES (e.g., "WORKS_AT", "DIAGNOSED_WITH").
- Do NOT output markdown formatting like ```json. Just raw JSON.
"""
