import logging
import uuid
from typing import Any

from qdrant_client import QdrantClient
from qdrant_client.models import (
    Distance,
    Modifier,
    PointStruct,
    SparseVector,
    SparseVectorParams,
    VectorParams,
)

from backend import context as byod_context

logger = logging.getLogger(__name__)

_CLIENT_CACHE: dict[tuple[str, str | None], Any] = {}
_INITIALIZED_COLLECTIONS: set[tuple[str, str]] = set()


def close_all_qdrant_clients():
    """Explicitly close all cached Qdrant clients (e.g. during app shutdown)."""
    for client in list(_CLIENT_CACHE.values()):
        try:
            client.close()
        except Exception as err:
            logger.debug("Failed closing cached Qdrant client: %s", err)
    _CLIENT_CACHE.clear()
    _INITIALIZED_COLLECTIONS.clear()


class QdrantStorageClient:
    def __init__(self, url: str | None = None, api_key: str | None = None):
        if url is None:
            from backend.config import get_config

            cfg = get_config()
            request_url = byod_context.request_qdrant_url.get()
            request_key = byod_context.request_qdrant_key.get()
            url = request_url if request_url else cfg.qdrant_url
            if api_key is None:
                api_key = request_key if request_key else cfg.qdrant_api_key
            self.collection_name = getattr(cfg, "qdrant_collection_name", "veraxi_vectors")
        else:
            self.collection_name = "veraxi_vectors"

        self._url = url
        from unittest.mock import Mock

        is_mock = isinstance(QdrantClient, Mock) or hasattr(
            QdrantClient, "_mock_return_value"
        )
        is_memory_or_path = url == ":memory:" or url.startswith(("file://", "./", "/"))
        cache_key = (url, api_key)

        if not is_mock and not is_memory_or_path and cache_key in _CLIENT_CACHE:
            self.client = _CLIENT_CACHE[cache_key]
            self._is_pooled = True
        else:
            if url == ":memory:":
                self.client = QdrantClient(":memory:")
            elif url.startswith("file://"):
                self.client = QdrantClient(path=url[len("file://") :])
            elif url.startswith(("./", "/")):
                self.client = QdrantClient(path=url)
            elif api_key:
                self.client = QdrantClient(url=url, api_key=api_key)
            else:
                self.client = QdrantClient(url=url)

            if not is_mock and not is_memory_or_path:
                _CLIENT_CACHE[cache_key] = self.client
                self._is_pooled = True
            else:
                self._is_pooled = False

    @classmethod
    def from_config(cls, config) -> "QdrantStorageClient":
        # Check if BYOD context variables are set (from request headers)
        request_url = byod_context.request_qdrant_url.get()
        request_key = byod_context.request_qdrant_key.get()

        url = request_url if request_url else config.qdrant_url
        api_key = request_key if request_key else config.qdrant_api_key

        return cls(url=url, api_key=api_key)

    def close(self, force: bool = False):
        if force or not getattr(self, "_is_pooled", False):
            try:
                self.client.close()
            except Exception as err:
                logger.debug("Failed closing Qdrant client: %s", err)

    def create_collection(
        self,
        collection_name: str,
        vector_size: int | None = None,
        distance_metric: str = "Cosine",
    ):
        """Create a collection if it doesn't already exist."""
        init_key = (self._url, collection_name)
        if (
            getattr(self, "_is_pooled", False)
            and init_key in _INITIALIZED_COLLECTIONS
            and self.client.collection_exists(collection_name)
        ):
            return

        if vector_size is None:
            from backend.config import get_config

            vector_size = get_config().embedding_dimension

        # Safely map the string to the official Qdrant Enum
        d_enum = Distance.COSINE
        if distance_metric.upper() == "EUCLID":
            d_enum = Distance.EUCLID
        elif distance_metric.upper() == "DOT":
            d_enum = Distance.DOT
        elif distance_metric.upper() == "MANHATTAN":
            d_enum = Distance.MANHATTAN

        try:
            collection_info = self.client.get_collection(collection_name)
            existing_size = None
            if hasattr(collection_info.config.params, "vectors"):
                v_params = collection_info.config.params.vectors
                if hasattr(v_params, "size"):
                    existing_size = v_params.size
                elif isinstance(v_params, dict) and "" in v_params:
                    existing_size = getattr(v_params[""], "size", None)

            recreate_needed = not collection_info.config.params.sparse_vectors or (
                existing_size is not None and existing_size != vector_size
            )
            if recreate_needed:
                self.client.delete_collection(collection_name)
        except Exception as e:
            import sentry_sdk

            sentry_sdk.capture_exception(e)

        if not self.client.collection_exists(collection_name):
            self.client.create_collection(
                collection_name=collection_name,
                vectors_config=VectorParams(size=vector_size, distance=d_enum),
                sparse_vectors_config={
                    "text-sparse": SparseVectorParams(modifier=Modifier.IDF)
                },
            )

        from qdrant_client.http import models

        for field in [
            "tenant_id",
            "file_hash",
            "document_id",
            "source",
            "source_type",
        ]:
            try:
                self.client.create_payload_index(
                    collection_name=collection_name,
                    field_name=field,
                    field_schema=models.PayloadSchemaType.KEYWORD,
                )
            except Exception as err:
                logger.debug("Payload index creation skipped for %s: %s", field, err)

        if getattr(self, "_is_pooled", False):
            _INITIALIZED_COLLECTIONS.add(init_key)

    def insert_points(
        self,
        collection_name: str,
        vectors: list[list[float]],
        sparse_vectors: list[dict] | None = None,
        payloads: list[dict[str, Any]] | None = None,
        tenant_id: str = "default",
    ) -> list[str]:
        """Insert vectors and payloads, returning their generated UUIDs."""
        if payloads is None:
            payloads = [{} for _ in vectors]
        if sparse_vectors is None:
            sparse_vectors = [{"indices": [], "values": []} for _ in vectors]

        for payload in payloads:
            payload["tenant_id"] = tenant_id

        points = []
        point_ids = []
        for vector, sparse, payload in zip(vectors, sparse_vectors, payloads):
            # Check for explicit ID in payload, or generate deterministic UUIDv5 from tenant + source + text
            explicit_id = payload.get("point_id") or payload.get("id")
            if explicit_id:
                point_id = str(explicit_id)
            else:
                source_key = payload.get("source") or payload.get("document_id") or ""
                text_content = payload.get("text", "")
                unique_key = f"{tenant_id}:{source_key}:{text_content}"
                point_id = str(uuid.uuid5(uuid.NAMESPACE_URL, unique_key))
            point_ids.append(point_id)

            # Combine dense and sparse into a dictionary for Qdrant
            qdrant_vector: dict[str, list[float] | SparseVector] = {
                "": vector,
                "text-sparse": SparseVector(
                    indices=sparse["indices"], values=sparse["values"]
                ),
            }

            points.append(
                PointStruct(id=point_id, vector=qdrant_vector, payload=payload)  # type: ignore[arg-type]
            )

        # Batch upsert in chunks of 100 to stay well under Qdrant's 32MB HTTP request limit
        batch_size = 100
        for i in range(0, len(points), batch_size):
            batch = points[i : i + batch_size]
            self.client.upsert(collection_name=collection_name, points=batch)
        return point_ids

    def get_points(
        self, collection_name: str, point_ids: list[str]
    ) -> list[dict[str, Any]]:
        """Get points by their IDs."""
        if not point_ids:
            return []
        batch_size = 100
        points = []
        for i in range(0, len(point_ids), batch_size):
            batch_ids = point_ids[i : i + batch_size]
            retrieved = self.client.retrieve(
                collection_name=collection_name,
                ids=batch_ids,
                with_payload=True,
                with_vectors=True,
            )
            points.extend(retrieved)
        return [{"id": p.id, "payload": p.payload, "vector": p.vector} for p in points]

    def search_hybrid(
        self,
        collection_name: str,
        query_vector: list[float],
        sparse_query_vector: dict,
        limit: int = 10,
        tenant_id: str = "default",
    ) -> list[dict[str, Any]]:
        """Search for similar vectors using Hybrid Search (Dense + Sparse with RRF)."""
        from qdrant_client.http import models

        query_filter = models.Filter(
            must=[
                models.FieldCondition(
                    key="tenant_id", match=models.MatchValue(value=tenant_id)
                )
            ]
        )

        from qdrant_client.http.exceptions import UnexpectedResponse

        try:
            results = self.client.query_points(
                collection_name=collection_name,
                prefetch=[
                    models.Prefetch(
                        query=models.SparseVector(
                            indices=sparse_query_vector["indices"],
                            values=sparse_query_vector["values"],
                        ),
                        using="text-sparse",
                        filter=query_filter,
                        limit=limit,
                    ),
                    models.Prefetch(
                        query=query_vector, using="", filter=query_filter, limit=limit
                    ),
                ],
                query=models.FusionQuery(fusion=models.Fusion.RRF),
                limit=limit,
                with_payload=True,
            ).points
        except UnexpectedResponse as e:
            if "Not found: Collection" in str(e):
                return []
            raise

        # Convert to same output format
        out = []
        for p in results:
            out.append({"id": p.id, "score": p.score, "payload": p.payload})
        return out

    def delete_points(self, collection_name: str, point_ids: list[str]):
        """Delete points by their IDs."""
        from qdrant_client.http import models

        self.client.delete(
            collection_name=collection_name,
            points_selector=models.PointIdsList(points=point_ids),  # type: ignore[arg-type]
        )

    def has_file_hash(
        self, collection_name: str, file_hash: str, tenant_id: str = "default"
    ) -> bool:
        """Check if any points with the given file_hash already exist for this tenant."""
        from qdrant_client.http import models

        try:
            count = self.client.count(
                collection_name=collection_name,
                count_filter=models.Filter(
                    must=[
                        models.FieldCondition(
                            key="tenant_id", match=models.MatchValue(value=tenant_id)
                        ),
                        models.FieldCondition(
                            key="file_hash", match=models.MatchValue(value=file_hash)
                        ),
                    ]
                ),
                exact=False,
            ).count
            return count > 0
        except Exception:
            return False

    def delete_by_document(
        self, collection_name: str, document_id: str, tenant_id: str = "default"
    ) -> int:
        """Delete all points belonging to a specific document_id for a tenant."""
        from qdrant_client.http import models

        try:
            count_before = self.client.count(
                collection_name=collection_name,
                count_filter=models.Filter(
                    must=[
                        models.FieldCondition(
                            key="tenant_id", match=models.MatchValue(value=tenant_id)
                        ),
                        models.FieldCondition(
                            key="document_id",
                            match=models.MatchValue(value=document_id),
                        ),
                    ]
                ),
                exact=True,
            ).count

            self.client.delete(
                collection_name=collection_name,
                points_selector=models.FilterSelector(
                    filter=models.Filter(
                        must=[
                            models.FieldCondition(
                                key="tenant_id",
                                match=models.MatchValue(value=tenant_id),
                            ),
                            models.FieldCondition(
                                key="document_id",
                                match=models.MatchValue(value=document_id),
                            ),
                        ]
                    )
                ),
            )
            return count_before
        except Exception:
            return 0

    def delete_tenant(self, collection_name: str, tenant_id: str):
        """Delete all points belonging to a specific tenant."""
        from qdrant_client.http import models

        self.client.delete(
            collection_name=collection_name,
            points_selector=models.FilterSelector(
                filter=models.Filter(
                    must=[
                        models.FieldCondition(
                            key="tenant_id", match=models.MatchValue(value=tenant_id)
                        )
                    ]
                )
            ),
        )

    def count(self, collection_name: str, tenant_id: str = "default") -> int:
        """Count the number of vectors for a given tenant."""
        from qdrant_client.http import models

        count_filter = models.Filter(
            must=[
                models.FieldCondition(
                    key="tenant_id", match=models.MatchValue(value=tenant_id)
                )
            ]
        )
        return self.client.count(
            collection_name=collection_name, count_filter=count_filter, exact=True
        ).count
