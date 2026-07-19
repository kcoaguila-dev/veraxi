from backend.mcp_server.llm_loop import answer_question
from langchain_core.messages import AIMessage
from unittest.mock import AsyncMock, patch
import uuid
import asyncio

thread_id = str(uuid.uuid4())
tenant_id = "test_tenant"

@patch("backend.mcp_server.llm_loop.ChatOpenAI")
def run_test(mock_chat):
    mock_instance = mock_chat.return_value
    mock_instance.bind_tools.return_value = mock_instance
    
    # Mock responses
    async def mock_invoke(messages):
        last_msg = messages[-1].content
        if "favorite color is Quantum Blue" in last_msg:
            return AIMessage(content="I will remember that your favorite color is Quantum Blue.")
        elif "favorite color" in last_msg:
            # The agent should have the previous messages in its state!
            # Let's check if the previous human message is in the messages list
            if any("Quantum Blue" in m.content for m in messages):
                return AIMessage(content="You told me your favorite color is Quantum Blue.")
            return AIMessage(content="I don't know your favorite color.")
        return AIMessage(content="Hello")
        
    mock_instance.ainvoke.side_effect = mock_invoke

    async def run_async_tests():
        print(f"Testing LangGraph Memory with thread_id: {thread_id}")
        print("\n--- TURN 1 ---")
        q1 = "Hello, my favorite color is Quantum Blue. Please remember that."
        print(f"User: {q1}")
        a1 = await answer_question(q1, tenant_id=tenant_id, thread_id=thread_id, return_context=False)
        print(f"Agent: {a1}")

        print("\n--- TURN 2 ---")
        q2 = "What did I say my favorite color was?"
        print(f"User: {q2}")
        a2 = await answer_question(q2, tenant_id=tenant_id, thread_id=thread_id, return_context=False)
        print(f"Agent: {a2}")

        if "Quantum Blue" in a2:
            print("\nSUCCESS! The agent remembered the color.")
        else:
            print("\nFAILURE! Memory did not persist.")
            
    asyncio.run(run_async_tests())

run_test()
