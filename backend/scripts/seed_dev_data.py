"""Veraxi Synthetic Developer Seeder.

Populates local Neo4j (Knowledge Graph) and Qdrant (Vectors) with a compact,
interrelated multi-hop dataset to enable instant offline/local testing
without external API keys or heavy batch pipelines.
"""

from __future__ import annotations

import argparse
import logging
import sys
from typing import Any

from backend.config import get_config
from backend.ingestion.chunk_embed import embed_text, embed_text_sparse
from backend.storage.neo4j_client import Neo4jStorageClient
from backend.storage.qdrant_client import QdrantStorageClient

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s | %(levelname)s | %(message)s"
)
logger = logging.getLogger("seed_dev_data")

# Cohesive sample multi-hop domain data
SAMPLE_DOCUMENTS = [
    {
        "title": "Acme Neurotech Origins",
        "text": (
            "Dr. Elena Rostova founded Acme Neurotech in 2021 to develop state-of-the-art "
            "causal reasoning engines and neural graph indexers for complex structured data."
        ),
        "source": "seed/founding_records.txt",
        "entities": [
            {
                "name": "Elena Rostova",
                "type": "Person",
                "properties": {"role": "Founder & Chief Scientist"},
            },
            {
                "name": "Acme Neurotech",
                "type": "Organization",
                "properties": {"founded_year": 2021, "domain": "Causal AI"},
            },
        ],
    },
    {
        "title": "Acme Neurotech Acquisition",
        "text": (
            "In late 2023, GlobalTech Holdings acquired Acme Neurotech in a $150 million transaction "
            "to strengthen its multi-hop retrieval and enterprise knowledge graph portfolio."
        ),
        "source": "seed/press_release_2023.txt",
        "entities": [
            {
                "name": "GlobalTech Holdings",
                "type": "Organization",
                "properties": {"industry": "Enterprise Software"},
            },
            {"name": "Acme Neurotech", "type": "Organization", "properties": {}},
        ],
    },
    {
        "title": "Veraxi Enterprise Deployment",
        "text": (
            "GlobalTech Holdings deployed the Veraxi platform across its infrastructure to fuse "
            "vector similarity search in Qdrant with relational graph traversals in Neo4j via Reciprocal Rank Fusion."
        ),
        "source": "seed/architecture_whitepaper.txt",
        "entities": [
            {"name": "GlobalTech Holdings", "type": "Organization", "properties": {}},
            {
                "name": "Veraxi",
                "type": "Technology",
                "properties": {"category": "Hybrid GraphRAG Engine"},
            },
            {
                "name": "Neo4j",
                "type": "Technology",
                "properties": {"category": "Graph Database"},
            },
            {
                "name": "Qdrant",
                "type": "Technology",
                "properties": {"category": "Vector Database"},
            },
        ],
    },
]

SAMPLE_RELATIONSHIPS = [
    ("Elena Rostova", "Acme Neurotech", "FOUNDED"),
    ("Acme Neurotech", "GlobalTech Holdings", "ACQUIRED_BY"),
    ("GlobalTech Holdings", "Veraxi", "DEPLOYS"),
    ("Veraxi", "Neo4j", "INTEGRATES"),
    ("Veraxi", "Qdrant", "INTEGRATES"),
]


def seed_database(tenant_id: str = "default", clean: bool = False) -> dict[str, Any]:
    """Seeds Neo4j and Qdrant with interrelated multi-hop data."""
    config = get_config()

    logger.info("Connecting to Neo4j and Qdrant...")
    neo4j = Neo4jStorageClient.from_config(config)
    qdrant = QdrantStorageClient.from_config(config)

    # 1. Verify connectivity
    try:
        neo4j.driver.verify_connectivity()
    except Exception as e:
        logger.error(
            "Could not connect to Neo4j. Ensure Docker stack is running ('make up'): %s",
            e,
        )
        sys.exit(1)

    # 2. Ensure Qdrant collection exists
    collection_name = config.qdrant_collection_name
    qdrant.create_collection(collection_name)

    # 3. Optional wipe of tenant data
    if clean:
        logger.info("Cleaning existing data for tenant '%s'...", tenant_id)
        # Delete Neo4j nodes for this tenant
        neo4j.execute_write(
            "MATCH (n) WHERE n.tenant_id = $tenant_id DETACH DELETE n",
            {"tenant_id": tenant_id},
        )
        # Delete Qdrant vectors for this tenant
        try:
            from qdrant_client.http import models as q_models

            qdrant.client.delete(
                collection_name=collection_name,
                points_selector=q_models.FilterSelector(
                    filter=q_models.Filter(
                        must=[
                            q_models.FieldCondition(
                                key="tenant_id",
                                match=q_models.MatchValue(value=tenant_id),
                            )
                        ]
                    )
                ),
            )
        except Exception as e:
            logger.warning(
                "Could not purge tenant points in Qdrant (will upsert): %s", e
            )

    # 4. Generate vectors and payload for Qdrant
    logger.info("Embedding %d seed documents...", len(SAMPLE_DOCUMENTS))
    dense_vectors: list[list[float]] = []
    sparse_vectors: list[dict[str, list]] = []
    payloads: list[dict[str, Any]] = []

    for doc in SAMPLE_DOCUMENTS:
        dense = embed_text(doc["text"])
        sparse = embed_text_sparse(doc["text"])
        dense_vectors.append(dense)
        sparse_vectors.append(sparse)
        payloads.append(
            {
                "text": doc["text"],
                "title": doc["title"],
                "source": doc["source"],
                "tenant_id": tenant_id,
                "neo4j_node_ids": [],  # will be populated after Neo4j writes
            }
        )

    point_ids = qdrant.insert_points(
        collection_name=collection_name,
        vectors=dense_vectors,
        sparse_vectors=sparse_vectors,
        payloads=payloads,
        tenant_id=tenant_id,
    )
    logger.info(
        "Inserted %d points into Qdrant collection '%s'.",
        len(point_ids),
        collection_name,
    )

    # 5. Insert entities and link to Qdrant point IDs in Neo4j
    logger.info("Writing knowledge graph entities and causal relationships to Neo4j...")
    entity_nodes: dict[str, str] = {}  # name -> node_id
    point_to_nodes: dict[str, list[str]] = {pid: [] for pid in point_ids}

    for i, doc in enumerate(SAMPLE_DOCUMENTS):
        doc_point_id = point_ids[i]
        for ent in doc["entities"]:
            ent_name = ent["name"]
            if ent_name in entity_nodes:
                continue  # already created

            props = ent.get("properties", {}).copy()
            props["name"] = ent_name
            props["tenant_id"] = tenant_id
            props["qdrant_point_id"] = doc_point_id

            node_id = neo4j.create_node(ent["type"], props)
            entity_nodes[ent_name] = node_id
            point_to_nodes[doc_point_id].append(node_id)

    # 6. Create relationships
    created_rels = 0
    for from_name, to_name, rel_type in SAMPLE_RELATIONSHIPS:
        from_id = entity_nodes.get(from_name)
        to_id = entity_nodes.get(to_name)
        if from_id and to_id:
            neo4j.create_relationship(
                from_id=from_id,
                to_id=to_id,
                rel_type=rel_type,
                properties={"tenant_id": tenant_id},
            )
            created_rels += 1

    # 7. Update Qdrant payloads with reciprocal Neo4j node IDs (invariant enforcement)
    for point_id, node_ids in point_to_nodes.items():
        if node_ids:
            qdrant.client.set_payload(
                collection_name=collection_name,
                payload={"neo4j_node_ids": node_ids},
                points=[point_id],
            )

    neo4j.close()

    summary = {
        "tenant_id": tenant_id,
        "qdrant_points": len(point_ids),
        "neo4j_nodes": len(entity_nodes),
        "neo4j_relationships": created_rels,
        "entities": list(entity_nodes.keys()),
    }

    logger.info(
        "Seeding complete! Added %d nodes, %d relationships, %d vectors.",
        len(entity_nodes),
        created_rels,
        len(point_ids),
    )
    return summary


def main():
    parser = argparse.ArgumentParser(description="Veraxi Local Development Data Seeder")
    parser.add_argument(
        "--tenant",
        type=str,
        default="default",
        help="Tenant ID to seed data into (default: 'default')",
    )
    parser.add_argument(
        "--clean",
        action="store_true",
        help="Purge existing data for this tenant before seeding",
    )
    args = parser.parse_args()

    summary = seed_database(tenant_id=args.tenant, clean=args.clean)
    print("\n" + "=" * 60)
    print("  Veraxi Synthetic Seed Data Ready")
    print("=" * 60)
    print(f"  Tenant ID       : {summary['tenant_id']}")
    print(f"  Vectors Indexed : {summary['qdrant_points']}")
    print(f"  Entities Created: {summary['neo4j_nodes']}")
    print(f"  Edges Created   : {summary['neo4j_relationships']}")
    print(f"  Sample Entities : {', '.join(summary['entities'][:4])}...")
    print("=" * 60)
    print("  You can now test multi-hop retrieval immediately:")
    print('    - Query via CLI: vx trace "Elena Rostova"')
    print("    - Query via MCP: mcp_build_lazy_dossier")
    print("    - UI Browser   : http://localhost:8000/docs\n")


if __name__ == "__main__":
    main()
