from typing import Dict, List, Any
from backend.config import get_config
from backend.storage.neo4j_client import Neo4jStorageClient

def get_graph_schema() -> Dict[str, List[str]]:
    """
    Retrieves all unique Node Labels and Relationship Types currently in the Neo4j database.
    This helps the Host AI understand the existing schema before inserting new data.
    """
    config = get_config()
    neo4j_client = Neo4jStorageClient.from_config(config)

    try:
        # Get all node labels
        labels_result = neo4j_client.execute_read("CALL db.labels() YIELD label RETURN label")
        labels = [row["label"] for row in labels_result]

        # Get all relationship types
        rels_result = neo4j_client.execute_read("CALL db.relationshipTypes() YIELD relationshipType RETURN relationshipType")
        relationship_types = [row["relationshipType"] for row in rels_result]

        return {
            "node_labels": labels,
            "relationship_types": relationship_types
        }
    finally:
        neo4j_client.close()
