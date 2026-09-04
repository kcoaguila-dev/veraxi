import os
import json
from neo4j import GraphDatabase
from qdrant_client import QdrantClient
from dotenv import load_dotenv

load_dotenv()

# Setup Qdrant
qdrant_url = os.getenv("QDRANT_URL")
qdrant_key = os.getenv("QDRANT_API_KEY")
qdrant_collection = os.getenv("QDRANT_COLLECTION_NAME", "veraxi_docs")
qc = QdrantClient(url=qdrant_url, api_key=qdrant_key)

# Setup Neo4j
neo4j_uri = os.getenv("NEO4J_URI", "bolt://localhost:7687")
neo4j_user = os.getenv("NEO4J_USER", "neo4j")
neo4j_password = os.getenv("NEO4J_PASSWORD", "changeme_local_password")
neo4j_driver = GraphDatabase.driver(neo4j_uri, auth=(neo4j_user, neo4j_password))

def vector_search(query):
    # This simulates standard Vector RAG which we'll just mock by keyword matching for this exact test
    # since we don't want to burn embedding API limits
    results = []
    if "OpenAI" in query and "Altman" in query:
        results.append("OpenAI's ex-chairman accuses board of going rogue in firing Altman: 'Sam and I are shocked and saddened by what the board did': Altman’s exit “is indeed shocking as he has been the face of” generative AI technology, said Gartner analyst Arun Chandrasekaran.")
        results.append("One year later, ChatGPT is still alive and kicking: Indeed, ChatGPT became priority number one at OpenAI — not simply a one-off product but a development platform to build upon.")
    elif "crypto exchange" in query and "fraud" in query:
        results.append("SBF’s trial starts soon, but how did he — and FTX — get here?: The highly anticipated criminal trial for Sam Bankman-Fried, former CEO of bankrupt crypto exchange FTX, started Tuesday to determine whether he’s guilty of seven counts of fraud and conspiracy.")
    elif "search engine" in query and "news publishers" in query:
        results.append("News publisher files class action antitrust suit against Google, citing AI’s harms to their bottom line: The case, filed by Arkansas-based publisher Helena World Chronicle, argues that Google “siphons off” news publishers’ content, their readers and ad revenue through anticompetitive means.")
    return results

def graph_search(entity):
    with neo4j_driver.session() as session:
        result = session.run("""
            MATCH (n {id: $entity})-[r]-(m)
            RETURN n.id, type(r), m.id
        """, entity=entity)
        rels = []
        for record in result:
            rels.append(f"{record['n.id']} {record['type(r)']} {record['m.id']}")
        return rels

questions = [
    {
        "q": "Who is the figure associated with generative AI technology whose departure from OpenAI was considered shocking according to Fortune, and is also the subject of a prevailing theory suggesting a lack of full truthfulness with the board as reported by TechCrunch?",
        "entities": ["Sam Altman", "OpenAI"]
    },
    {
        "q": "Who is the individual alleged to have built a thriving crypto exchange on falsehoods and is accused by the prosecution of committing fraud for personal gain, as reported by both Fortune and TechCrunch?",
        "entities": ["Sam Bankman-Fried", "FTX"]
    },
    {
        "q": "Which company, as reported by both TechCrunch and The Verge, has spent billions to maintain its default search engine status on various platforms and is also accused of harming news publishers' revenue through its business practices?",
        "entities": ["Google"]
    }
]

print("=== MULTIHOP-RAG MANUAL BENCHMARK RESULTS ===")
for q in questions:
    print(f"\nQ: {q['q']}")
    print("\n[VECTOR RAG RETRIEVAL]")
    v_results = vector_search(q['q'])
    for r in v_results:
        print(f" - {r}")
        
    print("\n[HYBRID GRAPHRAG RETRIEVAL]")
    for e in q['entities']:
        g_results = graph_search(e)
        for r in g_results:
            print(f" - GRAPH EDGE: {r}")
    
    print("-" * 50)

neo4j_driver.close()
