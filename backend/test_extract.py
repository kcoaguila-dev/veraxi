from langchain_core.messages import AIMessage, ToolMessage, HumanMessage

def _extract_messages_from_state(raw_messages: list, feedback_dict: dict = None) -> list:
    if feedback_dict is None:
        feedback_dict = {}
        
    tool_results = {}
    for msg in raw_messages:
        if getattr(msg, "type", "") == "tool" or msg.__class__.__name__ == "ToolMessage":
            tool_results[msg.tool_call_id] = msg.content
            
    messages_out = []
    for msg in raw_messages:
        msg_type = msg.__class__.__name__
        if msg_type in ["HumanMessage", "AIMessage"]:
            if msg_type == "HumanMessage" and msg.content:
                content_str = str(msg.content)
                if content_str.startswith("Here is the context retrieved from the database:") or content_str.startswith("Web Search Fallback Context:"):
                    continue
                    
            msg_id = getattr(msg, "id", None)
            if not msg_id:
                msg_id = getattr(msg, "additional_kwargs", {}).get("id") or str(id(msg))
            metrics = getattr(msg, "additional_kwargs", {}).get("metrics")
            
            tool_events = []
            if hasattr(msg, "tool_calls") and msg.tool_calls:
                for tc in msg.tool_calls:
                    tool_events.append({
                        "id": tc.get("id", ""),
                        "name": tc.get("name", "tool"),
                        "args": tc.get("args", {}),
                        "result": tool_results.get(tc.get("id"), ""),
                        "isComplete": True
                    })
            
            messages_out.append({
                "id": str(msg_id),
                "role": "user" if msg_type == "HumanMessage" else "assistant",
                "content": msg.content,
                "feedback": int(feedback_dict.get(str(msg_id), 0)),
                "model_name": getattr(msg, "additional_kwargs", {}).get("model_name"),
                "metrics": metrics if isinstance(metrics, dict) else None,
                "toolEvents": tool_events
            })
    return messages_out

raw = [
    HumanMessage(content="Hello"),
    AIMessage(content="", tool_calls=[{"name": "mcp_web_search", "args": {"query": "test"}, "id": "123"}]),
    ToolMessage(content="Search results for test", tool_call_id="123")
]
print(_extract_messages_from_state(raw))
