# Veraxi API & Tools Reference

This document serves as the single source of truth for interacting with the Veraxi infrastructure. It is divided into the HTTP REST Gateway, the Server-Sent Events (SSE) Transport layer, and the Model Context Protocol (MCP) Toolset.

## 1. HTTP API Gateway (FastAPI)
The API Gateway provides standard REST endpoints primarily used by the Flutter frontend.
All endpoints are secured via `Authorization: Bearer <tenant_id>`.

Interactive Swagger documentation is available at `http://<host>:8001/docs` when the server is running.

### Endpoints
- **`POST /api/chat`**: Submit a natural language question. Returns a GraphRAG answer.
- **`GET /api/admin/stats`**: Retrieve live node and vector counts for the authenticated tenant.
- **`POST /api/admin/ingest`**: Submit raw text for chunking, embedding, and Neo4j graph extraction.
- **`POST /api/admin/ingest/upload`**: Upload a document (PDF, DOCX) to be processed by Docling and ingested.
- **`POST /api/admin/ingest/url`**: Provide a URL to be scraped, processed by Docling, and ingested.


## 2. Model Context Protocol (MCP) Setup
Veraxi operates a fully spec-compliant MCP server over Server-Sent Events (SSE).
Host AIs (like Claude Desktop or custom agents) can connect to this stream to access the Veraxi GraphRAG tools.

### Endpoints
- **`GET /sse`**: Initiates the event stream. You must pass `Authorization: Bearer <tenant_id>` in the headers. This locks your connection to a specific knowledge graph tenant.
- **`POST /messages`**: The endpoint where JSON-RPC tool calls are sent. The specific URL is provided by the server upon successful `/sse` connection.


## 3. MCP Toolset, Resources, & Prompts
The following tools, resources, and prompts are exposed to connected Host AIs.

### Resources
Resources are static or live data endpoints that the Host AI can read directly without a tool call.

#### `veraxi://schema`
**Name**: Database Schema
**Description**: The ontology of the Neo4j Knowledge Graph.
**Mime Type**: application/json

#### `veraxi://stats`
**Name**: Database Statistics
**Description**: Live counts of nodes, vectors, and relationships for the current tenant.
**Mime Type**: application/json


### Prompts
Prompts are templates provided by the server to instruct the Host AI on specific workflows.

#### `ingest_knowledge`
**Description**: Provides strict instructions to the Host AI on how to read source material and construct GraphRAG structures.


### Tools
Tools allow the Host AI to take actions within the Veraxi ecosystem.

#### `mcp_search_vectors`
**Description**: Semantic search over documents
**Input Schema**:
```json
{
  "type": "object",
  "properties": {
    "query_text": {
      "type": "string"
    },
    "limit": {
      "type": "integer",
      "default": 10
    }
  },
  "required": [
    "query_text"
  ]
}
```

#### `mcp_query_graph`
**Description**: Find exact entity relationships
**Input Schema**:
```json
{
  "type": "object",
  "properties": {
    "entity_name": {
      "type": "string"
    },
    "max_hops": {
      "type": "integer",
      "default": 2
    }
  },
  "required": [
    "entity_name"
  ]
}
```

#### `mcp_insert_graph_nodes`
**Description**: Insert structured nodes and relations into the Neo4j Knowledge Graph. The Host AI should extract these from unstructured text first.
**Input Schema**:
```json
{
  "type": "object",
  "properties": {
    "nodes": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "type": {
            "type": "string"
          },
          "name": {
            "type": "string"
          },
          "properties": {
            "type": "object"
          }
        },
        "required": [
          "type",
          "name"
        ]
      }
    },
    "relations": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "from_entity": {
            "type": "string"
          },
          "to_entity": {
            "type": "string"
          },
          "type": {
            "type": "string"
          }
        },
        "required": [
          "from_entity",
          "to_entity",
          "type"
        ]
      }
    }
  },
  "required": [
    "nodes",
    "relations"
  ]
}
```

#### `mcp_insert_vectors`
**Description**: Generate embeddings and insert text chunks into the Qdrant Vector Database.
**Input Schema**:
```json
{
  "type": "object",
  "properties": {
    "texts": {
      "type": "array",
      "items": {
        "type": "string"
      }
    }
  },
  "required": [
    "texts"
  ]
}
```

#### `mcp_merge_rank`
**Description**: Perform a unified GraphRAG search. It searches vectors using query_text and traverses the graph from entity_name, then fuses the results using Reciprocal Rank Fusion.
**Input Schema**:
```json
{
  "type": "object",
  "properties": {
    "query_text": {
      "type": "string"
    },
    "entity_name": {
      "type": "string"
    },
    "limit": {
      "type": "integer",
      "default": 10
    },
    "max_hops": {
      "type": "integer",
      "default": 2
    }
  },
  "required": [
    "query_text",
    "entity_name"
  ]
}
```

#### `mcp_get_graph_schema`
**Description**: Retrieves all unique Node Labels and Relationship Types currently in the Neo4j database. Call this before inserting data to understand the ontology.
**Input Schema**:
```json
{
  "type": "object",
  "properties": {}
}
```

#### `mcp_delete_entity`
**Description**: Deletes a specific entity and all its relationships from Neo4j.
**Input Schema**:
```json
{
  "type": "object",
  "properties": {
    "entity_name": {
      "type": "string"
    }
  },
  "required": [
    "entity_name"
  ]
}
```

#### `mcp_delete_document`
**Description**: Deletes a specific document chunk from Qdrant using its document ID.
**Input Schema**:
```json
{
  "type": "object",
  "properties": {
    "document_id": {
      "type": "string"
    }
  },
  "required": [
    "document_id"
  ]
}
```

#### `mcp_update_entity`
**Description**: Updates the properties of an existing Neo4j entity. Only provide the properties you want to add or overwrite.
**Input Schema**:
```json
{
  "type": "object",
  "properties": {
    "entity_name": {
      "type": "string"
    },
    "properties": {
      "type": "object"
    }
  },
  "required": [
    "entity_name",
    "properties"
  ]
}
```

#### `mcp_get_database_stats`
**Description**: Retrieves high-level statistics about the size of the database (nodes, relationships, vectors).
**Input Schema**:
```json
{
  "type": "object",
  "properties": {}
}
```

#### `mcp_run_community_detection`
**Description**: Runs a Graph Data Science community detection algorithm to find clusters of connected entities.
**Input Schema**:
```json
{
  "type": "object",
  "properties": {
    "min_size": {
      "type": "integer",
      "default": 2
    }
  }
}
```

#### `mcp_delete_relationship`
**Description**: Deletes a specific relationship edge between two entities without deleting the entities themselves.
**Input Schema**:
```json
{
  "type": "object",
  "properties": {
    "from_entity": {
      "type": "string"
    },
    "to_entity": {
      "type": "string"
    },
    "rel_type": {
      "type": "string"
    }
  },
  "required": [
    "from_entity",
    "to_entity",
    "rel_type"
  ]
}
```

#### `mcp_update_document_metadata`
**Description**: Updates or adds metadata properties to an existing vector document chunk in Qdrant.
**Input Schema**:
```json
{
  "type": "object",
  "properties": {
    "document_id": {
      "type": "string"
    },
    "payload": {
      "type": "object"
    }
  },
  "required": [
    "document_id",
    "payload"
  ]
}
```

