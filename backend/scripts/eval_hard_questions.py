import json
import logging
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from backend.config import get_config
from backend.ingestion.chunk_embed import embed_text, embed_text_sparse
from backend.ingestion.document_parser import extract_verbatim_quote
from backend.mcp_server.tools.query_graph import query_graph
from backend.retrieval.merge_rank import VectorHit, merge_rank
from backend.storage.qdrant_client import QdrantStorageClient

logging.basicConfig(level=logging.WARNING)

TENANT_ID = os.getenv("TENANT_ID", "2b0d4cab-503e-4827-91d6-5806e587b15f")

QUESTIONS = [
    {
        "book": "The Art of Short Selling (Kathryn Staley)",
        "question": "What red flags in inventory accounting, such as inventory growing faster than sales or changes in LIFO reserves, indicate potential earnings manipulation or demand deterioration?",
        "entities": ["Inventory", "Sales", "Kathryn Staley", "LIFO"],
    },
    {
        "book": "Fooling Some of the People All of the Time (David Einhorn)",
        "question": "Why did David Einhorn challenge Allied Capital's valuation of its Business Loan Express (BLX) subsidiary, and what specific Small Business Administration (SBA) loan irregularities were uncovered?",
        "entities": ["David Einhorn", "Allied Capital", "Business Loan Express", "SBA"],
    },
    {
        "book": "Financial Shenanigans (Howard Schilit)",
        "question": "According to Howard Schilit, what are the primary warning signs of 'Shenanigan No. 2: Recording Bogus Revenue', such as supplier rebates, circular transactions, and unbilled receivables?",
        "entities": ["Howard Schilit", "Revenue", "Shenanigans", "Accounts Receivable"],
    },
    {
        "book": "Quality of Earnings (Thornton O'Glove)",
        "question": "How does Thornton O'Glove analyze the differential between reported net income and operating cash flow, and what role do non-operating gains and deferred taxes play in masking deteriorating earnings?",
        "entities": ["Thornton O'Glove", "Net Income", "Cash Flow", "Deferred Taxes"],
    },
]


def run_eval():
    config = get_config()
    qdrant = QdrantStorageClient.from_config(config)
    collection = config.qdrant_collection_name

    results = []

    for idx, item in enumerate(QUESTIONS, start=1):
        q = item["question"]
        target_book = item["book"]

        # 1. Vector Search (Dense + Sparse Hybrid in Qdrant)
        dense_vec = embed_text(q)
        sparse_vec = embed_text_sparse(q)

        raw_vector_hits = qdrant.search_hybrid(
            collection,
            query_vector=dense_vec,
            sparse_query_vector=sparse_vec,
            limit=10,
            tenant_id=TENANT_ID,
        )

        vector_hits = [
            VectorHit(
                id=h["id"],
                score=h["score"],
                payload=h["payload"],
            )
            for h in raw_vector_hits
        ]

        # 2. Graph Traversal (Neo4j entity-based retrieval via query_graph)
        graph_hits = []
        for ent_name in item["entities"]:
            g_hits = query_graph(ent_name, max_hops=2, tenant_id=TENANT_ID)
            graph_hits.extend(g_hits)

        # 3. Hybrid RRF Merge Rank
        fused = merge_rank(vector_hits, graph_hits, limit=5)

        # Extract Before (Vector Only top 3) vs After (Hybrid RRF top 3)
        vector_only_top = vector_hits[:3]
        hybrid_top = fused[:3]

        eval_entry = {
            "book": target_book,
            "question": q,
            "vector_only": [
                {
                    "id": h.id,
                    "score": round(h.score, 4),
                    "page": h.payload.get("page_number"),
                    "breadcrumb": h.payload.get("breadcrumb") or "N/A",
                    "is_table": bool(h.payload.get("is_table")),
                    "bbox": h.payload.get("bbox"),
                    "chunk": h.payload.get("chunk_index"),
                    "source": h.payload.get("source"),
                    "verbatim_quote": extract_verbatim_quote(
                        q, h.payload.get("text", "")
                    ),
                    "text_snippet": h.payload.get("text", "")[:220].strip() + "...",
                }
                for h in vector_only_top
            ],
            "hybrid_rrf": [
                {
                    "id": h.id,
                    "fused_score": round(h.fused_score, 4),
                    "sources": h.sources,
                    "page": h.payload.get("page_number"),
                    "breadcrumb": h.payload.get("breadcrumb") or "N/A",
                    "is_table": bool(h.payload.get("is_table")),
                    "bbox": h.payload.get("bbox"),
                    "chunk": h.payload.get("chunk_index"),
                    "source": h.payload.get("source"),
                    "verbatim_quote": extract_verbatim_quote(
                        q, h.payload.get("text", "")
                    ),
                    "text_snippet": h.payload.get("text", "")[:220].strip() + "...",
                }
                for h in hybrid_top
            ],
        }
        results.append(eval_entry)

    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    run_eval()
