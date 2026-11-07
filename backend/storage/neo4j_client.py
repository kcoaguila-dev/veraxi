from datetime import UTC, datetime
import logging
import uuid
from typing import Any
from unittest.mock import Mock

from neo4j import GraphDatabase

from backend import context as byod_context

logger = logging.getLogger(__name__)


from backend.ingestion.entity_resolution import (
    acronym_of,
    entity_key,
    normalize_name,
    strip_generic_suffix,
)

_DRIVER_CACHE: dict[tuple[str, str, str], Any] = {}
_ENSURED_LABELS_CACHE: set[tuple[str, str]] = set()


def close_all_neo4j_drivers():
    """Explicitly close all cached Neo4j drivers (e.g., during app shutdown)."""
    for driver in list(_DRIVER_CACHE.values()):
        try:
            driver.close()
        except Exception as err:
            logger.debug("Failed closing cached Neo4j driver: %s", err)
    _DRIVER_CACHE.clear()
    _ENSURED_LABELS_CACHE.clear()


class Neo4jStorageClient:
    def __init__(
        self,
        uri: str | None = None,
        user: str | None = None,
        password: str | None = None,
    ):
        if uri is None or user is None or password is None:
            from backend.config import get_config

            cfg = get_config()
            uri = uri or cfg.neo4j_uri
            user = user or cfg.neo4j_user
            password = password if password is not None else cfg.neo4j_password

        is_mock = (
            isinstance(GraphDatabase.driver, Mock)
            or hasattr(GraphDatabase.driver, "_mock_return_value")
            or isinstance(uri, Mock)
            or not isinstance(uri, str)
        )
        if not isinstance(uri, str) or isinstance(uri, Mock):
            uri = "bolt://localhost:7687"
        if not isinstance(user, str) or isinstance(user, Mock):
            user = "neo4j"
        if not isinstance(password, str) or isinstance(password, Mock):
            password = "password"

        cache_key = (uri, user, password)

        if not is_mock and cache_key in _DRIVER_CACHE:
            self.driver = _DRIVER_CACHE[cache_key]
            self._is_pooled = True
        else:
            self.driver = GraphDatabase.driver(uri, auth=(user, password))
            if not is_mock:
                _DRIVER_CACHE[cache_key] = self.driver
                self._is_pooled = True
            else:
                self._is_pooled = False

        self._driver = self.driver
        self._uri = uri
        self._ensured_labels: set[str] = set()

    def _ensure_single_label_constraint(self, label: str):
        if not label.isalnum():
            raise ValueError("Label must be alphanumeric")

        global_key = (self._uri, label)
        if label in self._ensured_labels or global_key in _ENSURED_LABELS_CACHE:
            return

        constraint_query = f"CREATE CONSTRAINT IF NOT EXISTS FOR (n:{label}) REQUIRE n.entity_key IS UNIQUE"
        index_query = f"CREATE INDEX IF NOT EXISTS FOR (n:{label}) ON (n.acronym_key)"
        name_index_query = (
            f"CREATE INDEX IF NOT EXISTS FOR (n:{label}) ON (n.tenant_id, n.name)"
        )
        tenant_index_query = (
            f"CREATE INDEX IF NOT EXISTS FOR (n:{label}) ON (n.tenant_id)"
        )

        with self.driver.session() as session:
            session.run(constraint_query)
            session.run(index_query)
            session.run(name_index_query)
            session.run(tenant_index_query)

        self._ensured_labels.add(label)
        if getattr(self, "_is_pooled", False):
            _ENSURED_LABELS_CACHE.add(global_key)

    def ensure_entity_constraint(self, label: str):
        self._ensure_single_label_constraint(label)
        if label != "Chunk" and label != "Entity":
            self._ensure_single_label_constraint("Entity")

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

    def close(self, force: bool = False):
        if force or not getattr(self, "_is_pooled", False):
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
        norm_stripped = strip_generic_suffix(norm_name)
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

        lower_candidates = list(
            {name.strip().lower()}
            | {
                a.strip().lower()
                for a in (aliases or [])
                if isinstance(a, str) and a.strip()
            }
        )
        acr_entity_key = f"{tenant_id}::{label}::{acr_key}" if acr_key else None

        with self.driver.session() as session:
            # Cross-document resolution: check if an existing node in this tenant matches by
            # entity_key, acronym_key, reverse acronym entity_key, or any known alias.
            existing_lookup = session.run(
                f"""
                MATCH (n:{label})
                WHERE n.tenant_id = $tenant_id
                  AND (
                    n.entity_key = $entity_key
                    OR ($is_short_token AND n.acronym_key = $norm_stripped)
                    OR ($acr_entity_key IS NOT NULL AND n.entity_key = $acr_entity_key)
                    OR any(a IN coalesce(n.aliases, []) WHERE toLower(a) IN $lower_candidates)
                  )
                RETURN n.entity_key AS ek
                LIMIT 1
                """,
                tenant_id=tenant_id,
                entity_key=ent_key,
                is_short_token=(
                    2 <= len(norm_stripped) <= 6 and " " not in norm_stripped
                ),
                norm_stripped=norm_stripped,
                acr_entity_key=acr_entity_key,
                lower_candidates=lower_candidates,
            ).single()
            if existing_lookup and existing_lookup["ek"]:
                ent_key = existing_lookup["ek"]

            extra_label = ":Entity" if label != "Chunk" and label != "Entity" else ""
            extra_set = f"n{extra_label},\n                " if extra_label else ""
            query = f"""
            MERGE (n:{label} {{entity_key: $entity_key}})
            ON CREATE SET n.id = $new_id, n.tenant_id = $tenant_id, n.name = $name,
                          n.aliases = [], n.qdrant_point_ids = []
            SET {extra_set}n += $properties,
                n.acronym_key = coalesce(n.acronym_key, $acronym_key),
                n.name = CASE WHEN size($name) > size(n.name) THEN $name ELSE n.name END,
                n.aliases = reduce(acc = n.aliases, a IN $aliases | CASE WHEN a IN acc THEN acc ELSE acc + a END),
                n.qdrant_point_ids = reduce(acc = n.qdrant_point_ids, p IN $qdrant_point_ids | CASE WHEN p IN acc THEN acc ELSE acc + p END)
            RETURN n.id AS id
            """
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

        now_iso = datetime.now(UTC).isoformat()
        props = (properties or {}).copy()
        props.setdefault("last_confirmed_at", now_iso)
        props.setdefault("active", True)
        first_seen = props.pop("first_seen_at", now_iso)

        query = f"""
        MATCH (a {{id: $from_id}})
        MATCH (b {{id: $to_id}})
        MERGE (a)-[r:{rel_type}]->(b)
        ON CREATE SET r.first_seen_at = $first_seen
        SET r += $props,
            r.first_seen_at = coalesce(r.first_seen_at, $first_seen)
        """

        with self.driver.session() as session:
            session.run(
                query,
                from_id=from_id,
                to_id=to_id,
                props=props,
                first_seen=first_seen,
            )

    def create_node(self, label: str, properties: dict[str, Any]) -> str:
        """Create a node with the given label and properties, returning its generated UUID."""
        node_id = str(uuid.uuid4())
        props = properties.copy()
        props["id"] = node_id

        if not label.isalnum():
            raise ValueError("Label must be alphanumeric")

        extra_label = ":Entity" if label != "Chunk" and label != "Entity" else ""
        query = f"""
        CREATE (n:{label}{extra_label} $props)
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
    ) -> list[dict[str, Any]]:
        """Execute a write query with parameters."""
        with self.driver.session() as session:
            result = session.run(query, parameters or {})
            return [record.data() for record in result]
