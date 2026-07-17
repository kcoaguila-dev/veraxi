import uuid
from typing import Dict, Any, Optional, List

from neo4j import GraphDatabase


class Neo4jStorageClient:
    def __init__(self, uri: str, user: str, password: str):
        self.driver = GraphDatabase.driver(uri, auth=(user, password))

    def close(self):
        self.driver.close()

    def create_node(self, label: str, properties: Dict[str, Any]) -> str:
        """Create a node with the given label and properties, returning its generated UUID."""
        node_id = str(uuid.uuid4())
        props = properties.copy()
        props["id"] = node_id

        # We can parameterize properties, but label cannot be parameterized in Neo4j.
        # We will inject the label string directly but parameterize the properties.
        # However, to avoid injection, we'll validate the label string.
        if not label.isalnum():
            raise ValueError("Label must be alphanumeric")

        query = f"""
        CREATE (n:{label} $props)
        RETURN n.id AS id
        """

        with self.driver.session() as session:
            result = session.run(query, props=props)
            record = result.single()
            if record:
                return record["id"]
        return ""

    def create_relationship(
        self,
        from_id: str,
        to_id: str,
        rel_type: str,
        properties: Optional[Dict[str, Any]] = None,
    ):
        """Create a relationship between two nodes by their IDs."""
        if not rel_type.replace("_", "").isalnum():
            raise ValueError("Relationship type must be alphanumeric/underscores")

        props = properties or {}

        query = f"""
        MATCH (a {{id: $from_id}})
        MATCH (b {{id: $to_id}})
        CREATE (a)-[r:{rel_type} $props]->(b)
        """

        with self.driver.session() as session:
            session.run(query, from_id=from_id, to_id=to_id, props=props)

    def execute_read(
        self, query: str, parameters: Optional[Dict[str, Any]] = None
    ) -> List[Dict[str, Any]]:
        """Execute a read query with parameters."""
        with self.driver.session() as session:
            result = session.run(query, parameters or {})
            return [record.data() for record in result]
