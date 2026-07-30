import asyncio
from mcp.server import Server
import mcp.types as types

async def on_list_resources(ctx, req):
    return types.ListResourcesResult(resources=[
        types.Resource(uri="veraxi://schema", name="Schema")
    ])

async def on_read_resource(ctx, req):
    return types.ReadResourceResult(contents=[
        types.TextResourceContents(uri=req.uri, mimeType="application/json", text="[]")
    ])

async def on_list_prompts(ctx, req):
    return types.ListPromptsResult(prompts=[
        types.Prompt(name="test", description="desc")
    ])

async def on_get_prompt(ctx, req):
    return types.GetPromptResult(description="", messages=[
        types.PromptMessage(role="user", content=types.TextContent(type="text", text="hello"))
    ])

s = Server("test", 
           on_list_resources=on_list_resources,
           on_read_resource=on_read_resource,
           on_list_prompts=on_list_prompts,
           on_get_prompt=on_get_prompt)
print("Server configured properly.")
