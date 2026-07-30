import re

with open("mcp_server/server.py", "r") as f:
    content = f.read()

# Add new imports
content = content.replace("from mcp.types import Tool, TextContent, Resource, Prompt, PromptMessage", 
                          "from mcp.types import Tool, TextContent, Resource, Prompt, PromptMessage, ListResourcesResult, ReadResourceResult, TextResourceContents, ListPromptsResult, GetPromptResult, ListToolsResult, CallToolResult")

# Remove decorators and change signatures
content = re.sub(r'@mcp_server\.list_resources\(\)\nasync def handle_list_resources\(\) -> list\[Resource\]:',
                 r'async def handle_list_resources(ctx, params) -> ListResourcesResult:', content)

content = content.replace("return [\n        Resource", "return ListResourcesResult(resources=[\n        Resource")
content = re.sub(r'(\s*)\}\n\s*\]', r'\1}\n    ])', content) # doesn't apply to resources easily, I will just do exact replace

