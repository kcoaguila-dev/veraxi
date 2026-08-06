import pytest
import httpx
import json

@pytest.mark.asyncio
async def test_e2e_web_search_live_backend():
    """
    E2E test that hits the live backend on localhost:8000
    to verify that the web search flow works with the Groq model
    without failing on tool-calling errors.
    """
    import os
    groq_api_key = os.environ.get("GROQ_API_KEY")
    if not groq_api_key:
        pytest.skip("GROQ_API_KEY not set in environment. Skipping live e2e test.")
        
    try:
        async with httpx.AsyncClient() as client:
            response = await client.post(
                "http://localhost:8000/api/chat",
                json={
                    "question": "What is today's news?", 
                    "stream": True, 
                    "model": "llama-3.1-8b-instant",
                    "api_key": groq_api_key
                },
                timeout=60.0
            )
            assert response.status_code == 200
            
            content_received = False
            done_received = False
            
            async for line in response.aiter_lines():
                line = line.strip()
                if not line:
                    continue
                    
                if line.startswith("data: "):
                    data_str = line[6:]
                    if data_str == "[DONE]":
                        done_received = True
                        break
                    
                    try:
                        event = json.loads(data_str)
                        if "error" in event:
                            pytest.fail(f"Backend returned an error event: {event['error']}")
                        if event.get("event") == "on_chat_model_stream":
                            chunk = event.get("data", {}).get("chunk", {})
                            if chunk.get("content"):
                                content_received = True
                    except json.JSONDecodeError:
                        pass
                        
            assert content_received, "No content was streamed back from the model"
            assert done_received, "Stream did not complete with [DONE]"
            
    except httpx.ConnectError:
        pytest.skip("Backend is not running at localhost:8000")
