from backend.storage.neo4j_client import Neo4jStorageClient
from backend.config import Config

config = Config.from_env()
neo4j = Neo4jStorageClient.from_config(config)
query = "MATCH (n) RETURN distinct labels(n) as labels"
results = neo4j.execute_read(query)
print("Books currently in Neo4j:")
for r in results:
    print("- " + str(r["source"]))
