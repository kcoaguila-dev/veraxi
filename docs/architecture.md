```mermaid
graph TD
    subgraph Flutter["Flutter app (Dart)"]
        Chat["features/chat"]
        Control["features/control_panel"]
        Core["core/mcp_client"]
    end
    subgraph Backend["Python backend"]
        MCP["mcp_server (tools)"]
        Retrieval["retrieval/merge_rank"]
        Ingestion["ingestion pipeline"]
    end
    subgraph Storage["Data stores"]
        Neo4j[("Neo4j - graph")]
        Qdrant[("Qdrant - vectors")]
    end
    Chat --> Core
    Control --> Core
    Core -- "MCP calls" --> MCP
    MCP --> Retrieval
    Retrieval --> Neo4j
    Retrieval --> Qdrant
    Ingestion --> Neo4j
    Ingestion --> Qdrant