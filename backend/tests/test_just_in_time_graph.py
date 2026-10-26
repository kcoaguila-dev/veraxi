import uuid
import pytest
from backend.config import get_config
from backend.storage.neo4j_client import Neo4jStorageClient
from backend.mcp_server.tools.insert_graph import insert_graph_nodes, purge_cooccurrence_relationships
from backend.retrieval.just_in_time_graph import build_lazy_graph_dossier


@pytest.fixture
def test_tenant():
    return f"test-jit-{uuid.uuid4().hex[:8]}"


def test_insert_and_merge_graph_nodes(test_tenant):
    config = get_config()
    neo4j = Neo4jStorageClient.from_config(config)

    try:
        # Step 1: Insert initial nodes
        res1 = insert_graph_nodes(
            nodes=[
                {"type": "Company", "name": "Allied Capital", "properties": {"ticker": "ALD"}},
                {"type": "Person", "name": "David Einhorn", "properties": {"role": "Short Seller"}},
            ],
            relations=[],
            tenant_id=test_tenant,
        )
        assert res1["status"] == "success"
        assert res1["nodes_new"] == 2

        # Step 2: Merge the same nodes with an additional property and a rich causal relation
        res2 = insert_graph_nodes(
            nodes=[
                {"type": "Company", "name": "Allied Capital", "properties": {"sector": "Financials"}},
            ],
            relations=[
                {
                    "from_entity": "David Einhorn",
                    "to_entity": "Allied Capital",
                    "type": "INVESTIGATED",
                    "properties": {"year": 2002, "focus": "SBA Loan Marks"},
                }
            ],
            tenant_id=test_tenant,
        )
        assert res2["status"] == "success"
        assert res2["nodes_new"] == 0  # Should not create duplicate node!
        assert res2["relations_inserted"] == 1

        # Step 3: Verify in Neo4j
        query = """
        MATCH (a {name: 'David Einhorn', tenant_id: $tenant_id})-[r:INVESTIGATED]->(b {name: 'Allied Capital', tenant_id: $tenant_id})
        RETURN a.role AS role, b.sector AS sector, b.ticker AS ticker, r.year AS year, r.tenant_id AS rel_tenant
        """
        records = neo4j.execute_read(query, {"tenant_id": test_tenant})
        assert len(records) == 1
        rec = records[0]
        assert rec["role"] == "Short Seller"
        assert rec["sector"] == "Financials"
        assert rec["ticker"] == "ALD"
        assert rec["year"] == 2002
        assert rec["rel_tenant"] == test_tenant

    finally:
        # Cleanup
        neo4j.execute_write("MATCH (n {tenant_id: $tenant_id}) DETACH DELETE n", {"tenant_id": test_tenant})
        neo4j.close()


def test_purge_cooccurrence_relationships(test_tenant):
    config = get_config()
    neo4j = Neo4jStorageClient.from_config(config)

    try:
        # Insert nodes with both a MENTIONED_WITH and an INVESTIGATED relationship
        insert_graph_nodes(
            nodes=[
                {"type": "Company", "name": "BLX", "properties": {}},
                {"type": "Company", "name": "Allied Capital", "properties": {}},
            ],
            relations=[
                {"from_entity": "BLX", "to_entity": "Allied Capital", "type": "MENTIONED_WITH"},
                {"from_entity": "BLX", "to_entity": "Allied Capital", "type": "SUBSIDIARY_OF"},
            ],
            tenant_id=test_tenant,
        )

        # Verify 2 relationships exist
        q_count = "MATCH ()-[r {tenant_id: $tenant_id}]->() RETURN count(r) AS cnt"
        res_before = neo4j.execute_read(q_count, {"tenant_id": test_tenant})
        assert res_before[0]["cnt"] == 2

        # Purge only MENTIONED_WITH
        purge_res = purge_cooccurrence_relationships(tenant_id=test_tenant)
        assert purge_res["status"] == "success"
        assert purge_res["deleted_relationships"] == 1

        # Verify only SUBSIDIARY_OF remains
        q_remaining = "MATCH ()-[r {tenant_id: $tenant_id}]->() RETURN type(r) AS t"
        res_after = neo4j.execute_read(q_remaining, {"tenant_id": test_tenant})
        assert len(res_after) == 1
        assert res_after[0]["t"] == "SUBSIDIARY_OF"

        # Verify nodes are still intact
        q_nodes = "MATCH (n {tenant_id: $tenant_id}) RETURN count(n) AS cnt"
        res_nodes = neo4j.execute_read(q_nodes, {"tenant_id": test_tenant})
        assert res_nodes[0]["cnt"] == 2

    finally:
        neo4j.execute_write("MATCH (n {tenant_id: $tenant_id}) DETACH DELETE n", {"tenant_id": test_tenant})
        neo4j.close()


def test_build_lazy_graph_dossier_structure():
    # Test on the live tenant with ingested books
    tenant_id = "2b0d4cab-503e-4827-91d6-5806e587b15f"
    dossier = build_lazy_graph_dossier(
        query="Allied Capital David Einhorn SBA loan default",
        tenant_id=tenant_id,
        limit=5,
    )
    assert "chunks" in dossier
    assert "host_ai_instruction" in dossier
    assert len(dossier["chunks"]) > 0
    first_chunk = dossier["chunks"][0]
    assert "point_id" in first_chunk
    assert "text" in first_chunk
    assert "title" in first_chunk
    assert len(first_chunk["text"]) > 20
