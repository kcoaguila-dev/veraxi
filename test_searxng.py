from backend.mcp_server.tools.web_search import mcp_web_search
import json

print("Testing SearXNG Web Search Tool...")
# Using a query we expect to return results
results = mcp_web_search("Veraxi AI Agent", max_results=2)

if results:
    print(f"Success! Found {len(results)} results:")
    print(json.dumps(results, indent=2))
else:
    print("Failed to find results or SearXNG instance is unreachable.")
