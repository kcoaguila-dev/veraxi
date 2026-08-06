import uuid
from typing import List, Dict, Any, Optional

from qdrant_client import QdrantClient
from qdrant_client.models import PointStruct, Distance, VectorParams, SparseVectorParams, Modifier, SparseVector


class QdrantStorageClient:
    def __init__(self, url: str, api_key: Optional[str] = None):
        if api_key:
            self.client = QdrantClient(url=url, api_key=api_key)
        else:
            self.client = QdrantClient(url=url)

    @classmethod
    def from_config(cls, config) -> "QdrantStorageClient":
        return cls(url=config.qdrant_url, api_key=config.qdrant_api_key)

    def create_collection(self, collection_name: str, vector_size: int = 384, distance_metric: str = "Cosine"):
        """Create a collection if it doesn't already exist."""
        
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
            if not collection_info.config.params.sparse_vectors:
                self.client.delete_collection(collection_name)
        except Exception:
            pass

        if not self.client.collection_exists(collection_name):
            self.client.create_collection(
                collection_name=collection_name,
                vectors_config=VectorParams(size=vector_size, distance=d_enum),
                sparse_vectors_config={
                    "text-sparse": SparseVectorParams(
                        modifier=Modifier.IDF
                    )
                }
            )

    def insert_points(
        self,
        collection_name: str,
        vectors: List[List[float]],
        sparse_vectors: List[dict] = None,
        payloads: List[Dict[str, Any]] = None,
        tenant_id: str = "default",
    ) -> List[str]:
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
            point_id = str(uuid.uuid4())
            point_ids.append(point_id)
            
            # Combine dense and sparse into a dictionary for Qdrant
            qdrant_vector = {
                "": vector,
                "text-sparse": SparseVector(
                    indices=sparse["indices"],
                    values=sparse["values"]
                )
            }
            
            points.append(PointStruct(id=point_id, vector=qdrant_vector, payload=payload))

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

    def search_hybrid(
        self,
        collection_name: str,
        query_vector: List[float],
        sparse_query_vector: dict,
        limit: int = 10,
        tenant_id: str = "default",
    ) -> List[Dict[str, Any]]:
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
                            values=sparse_query_vector["values"]
                        ),
                        using="text-sparse",
                        filter=query_filter,
                        limit=limit
                    ),
                    models.Prefetch(
                        query=query_vector,
                        using="",
                        filter=query_filter,
                        limit=limit
                    )
                ],
                query=models.FusionQuery(fusion=models.Fusion.RRF),
                limit=limit,
                with_payload=True,
            ).points
        except UnexpectedResponse as e:
            if "Not found: Collection" in str(e):
                return []
            raise e

        # Convert to same output format
        out = []
        for p in results:
            out.append({"id": p.id, "score": p.score, "payload": p.payload})
        return out



    def delete_points(self, collection_name: str, point_ids: List[str]):
        """Delete points by their IDs."""
        from qdrant_client.http import models
        self.client.delete(
            collection_name=collection_name,
            points_selector=models.PointIdsList(points=point_ids)
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
            collection_name=collection_name,
            count_filter=count_filter,
            exact=True
        ).count
