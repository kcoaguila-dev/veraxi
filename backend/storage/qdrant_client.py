import uuid
from typing import List, Dict, Any, Optional

from qdrant_client import QdrantClient
from qdrant_client.models import PointStruct, Distance, VectorParams


class QdrantStorageClient:
    def __init__(self, url: str, api_key: Optional[str] = None):
        if api_key:
            self.client = QdrantClient(url=url, api_key=api_key)
        else:
            self.client = QdrantClient(url=url)

    def create_collection(self, collection_name: str, vector_size: int = 384):
        """Create a collection if it doesn't already exist."""
        if not self.client.collection_exists(collection_name):
            self.client.create_collection(
                collection_name=collection_name,
                vectors_config=VectorParams(size=vector_size, distance=Distance.COSINE),
            )

    def insert_points(
        self,
        collection_name: str,
        vectors: List[List[float]],
        payloads: List[Dict[str, Any]] = None,
        tenant_id: str = "default",
    ) -> List[str]:
        """Insert vectors and payloads, returning their generated UUIDs."""
        if payloads is None:
            payloads = [{} for _ in vectors]

        for payload in payloads:
            payload["tenant_id"] = tenant_id

        points = []
        point_ids = []
        for vector, payload in zip(vectors, payloads):
            point_id = str(uuid.uuid4())
            point_ids.append(point_id)
            points.append(PointStruct(id=point_id, vector=vector, payload=payload))

        self.client.upsert(collection_name=collection_name, points=points)
        return point_ids

    def get_points(
        self, collection_name: str, point_ids: List[str]
    ) -> List[Dict[str, Any]]:
        """Get points by their IDs."""
        points = self.client.retrieve(
            collection_name=collection_name,
            ids=point_ids,
            with_payload=True,
            with_vectors=True,
        )
        return [{"id": p.id, "payload": p.payload, "vector": p.vector} for p in points]

    def search(
        self,
        collection_name: str,
        query_vector: List[float],
        limit: int = 10,
        tenant_id: str = "default",
    ) -> List[Dict[str, Any]]:
        """Search for similar vectors."""
        from qdrant_client.http import models

        query_filter = models.Filter(
            must=[
                models.FieldCondition(
                    key="tenant_id", match=models.MatchValue(value=tenant_id)
                )
            ]
        )

        results = self.client.query_points(
            collection_name=collection_name,
            query=query_vector,
            limit=limit,
            query_filter=query_filter,
            with_payload=True,
        ).points
        return [
            {"id": hit.id, "score": hit.score, "payload": hit.payload}
            for hit in results
        ]
