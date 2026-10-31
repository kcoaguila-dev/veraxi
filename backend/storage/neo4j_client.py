import uuid
from typing import Any

from neo4j import GraphDatabase

from backend import context as byod_context


from backend.ingestion.entity_resolution import entity_key, normalize_name, acronym_of


class Neo4jStorageClient:
    def __init__(self, uri: str, user: str, password: str):
        self.driver = GraphDatabase.driver(uri, auth=(user, password))
        self._ensured_labels: set[str] = set()

    def ensure_entity_constraint(self, label: str):
        if not label.isalnum():
            raise ValueError("Label must be alphanumeric")

        if label in self._ensured_labels:
            return

        constraint_query = f"CREATE CONSTRAINT IF NOT EXISTS FOR (n:{label}) REQUIRE n.entity_key IS UNIQUE"
        index_query = f"CREATE INDEX IF NOT EXISTS FOR (n:{label}) ON (n.acronym_key)"

        with self.driver.session() as session:
            session.run(constraint_query)
            session.run(index_query)

        self._ensured_labels.add(label)

    @classmethod
    def from_config(cls, config) -> "Neo4jStorageClient":
        # Check if BYOD context variables are set (from request headers)
        request_uri = byod_context.request_neo4j_uri.get()
        request_user = byod_context.request_neo4j_user.get()
        request_pass = byod_context.request_neo4j_pass.get()

        uri = request_uri if request_uri else config.neo4j_uri
        user = request_user if request_user else config.neo4j_user
        password = request_pass if request_pass else config.neo4j_password

        return cls(uri=uri, user=user, password=password)

    def close(self):
        self.driver.close()

    def upsert_entity(
        self,
        label: str,
        tenant_id: str,
        name: str,
        aliases: list[str],
        properties: dict[str, Any],
        qdrant_point_ids: list[str],
    ) -> str:
        if not label.isalnum():
            raise ValueError("Label must be alphanumeric")

        self.ensure_entity_constraint(label)

        norm_name = normalize_name(name)
        ent_key = entity_key(tenant_id, label, name)
        acr_key = acronym_of(norm_name)

        props = properties.copy()
        for k in [
            "id",
            "tenant_id",
            "entity_key",
            "name",
            "aliases",
            "qdrant_point_ids",
            "acronym_key",
        ]:
            props.pop(k, None)

        query = f"""
        MERGE (n:{label} {{entity_key: $entity_key}})
        ON CREATE SET n.id = $new_id, n.tenant_id = $tenant_id, n.name = $name,
                      n.aliases = [], n.qdrant_point_ids = []
        SET n += $properties,
            n.acronym_key = $acronym_key,
            n.name = CASE WHEN size($name) > size(n.name) THEN $name ELSE n.name END,
            n.aliases = reduce(acc = n.aliases, a IN $aliases | CASE WHEN a IN acc THEN acc ELSE acc + a END),
            n.qdrant_point_ids = reduce(acc = n.qdrant_point_ids, p IN $qdrant_point_ids | CASE WHEN p IN acc THEN acc ELSE acc + p END)
        RETURN n.id AS id
        """

        with self.driver.session() as session:
            result = session.run(
                query,
                entity_key=ent_key,
                new_id=str(uuid.uuid4()),
                tenant_id=tenant_id,
                name=name,
                properties=props,
                acronym_key=acr_key,
                aliases=aliases,
                qdrant_point_ids=qdrant_point_ids,
            )
            record = result.single()
            if record:
                return record["id"]
        return ""

    def upsert_relationship(
        self, from_id: str, to_id: str, rel_type: str, properties: dict[str, Any]
    ):
        if not rel_type.replace("_", "").isalnum():
            raise ValueError("Relationship type must be alphanumeric/underscores")

        props = properties or {}

        query = f"""
        MATCH (a {{id: $from_id}})
        MATCH (b {{id: $to_id}})
        MERGE (a)-[r:{rel_type}]->(b)
        SET r += $props
        """

        with self.driver.session() as session:
            session.run(query, from_id=from_id, to_id=to_id, props=props)

    def create_relationship(
        self,
        from_id: str,
        to_id: str,
        rel_type: str,
        properties: dict[str, Any] | None = None,
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
        self, query: str, parameters: dict[str, Any] | None = None
    ) -> list[dict[str, Any]]:
        """Execute a read query with parameters."""
        with self.driver.session() as session:
            result = session.run(query, parameters or {})
            return [record.data() for record in result]

    def execute_write(
        self, query: str, parameters: dict[str, Any] | None = None
    ) -> None:
        """Execute a write query with parameters."""
        with self.driver.session() as session:
            session.run(query, parameters or {})
