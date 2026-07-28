import asyncio
import json
from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse

app = FastAPI()

async def generate_mock_sse():
    chunks = ["Hello", " from", " the", " Mock", " LLM", " Server", "!"]
    
    for i, chunk in enumerate(chunks):
        data = {
            "id": "chatcmpl-mock123",
            "object": "chat.completion.chunk",
            "created": 1694268190,
            "model": "mock-model",
            "choices": [
                {
                    "index": 0,
                    "delta": {"content": chunk},
                    "finish_reason": None
                }
            ]
        }
        yield f"data: {json.dumps(data)}\n\n"
        await asyncio.sleep(0.1)

    # Final chunk
    final_data = {
        "id": "chatcmpl-mock123",
        "object": "chat.completion.chunk",
        "created": 1694268190,
        "model": "mock-model",
        "choices": [
            {
                "index": 0,
                "delta": {},
                "finish_reason": "stop"
            }
        ]
    }
    yield f"data: {json.dumps(final_data)}\n\n"
    yield "data: [DONE]\n\n"

@app.post("/chat/completions")
async def chat_completions(request: Request):
    # LangChain ChatOpenAI will hit this endpoint
    body = await request.json()
    model = body.get("model")
    
    if model == "gemini-2.5-flash":
        from fastapi import HTTPException
        raise HTTPException(status_code=404, detail=f"The model `{model}` does not exist or you do not have access to it.")

    if body.get("stream", False):
        return StreamingResponse(generate_mock_sse(), media_type="text/event-stream")
    
    # Non-streaming fallback
    return {
        "id": "chatcmpl-mock123",
        "object": "chat.completion",
        "created": 1694268190,
        "model": "mock-model",
        "choices": [
            {
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": "Hello from the Mock LLM Server!"
                },
                "finish_reason": "stop"
            }
        ],
        "usage": {"prompt_tokens": 0, "completion_tokens": 7, "total_tokens": 7}
    }

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8001)
