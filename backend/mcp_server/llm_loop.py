import logging
import sentry_sdk
import json
from typing import Tuple, List, Any, TypedDict, Annotated, Sequence
from langchain_openai import ChatOpenAI
import asyncio
import urllib.request
import urllib.parse
from pydantic import BaseModel, Field
from langchain_core.messages import BaseMessage, HumanMessage, ToolMessage, AIMessage
from langgraph.graph import StateGraph, START, END
from langgraph.graph.message import add_messages
from langgraph.checkpoint.redis.aio import AsyncRedisSaver
import redis.asyncio as redis_async

from backend.config import get_config
from backend.mcp_server.tools.search_vectors import search_vectors
from backend.mcp_server.tools.query_graph import query_graph
from backend.retrieval.merge_rank import merge_rank

logger = logging.getLogger(__name__)

# We will initialize the connection dynamically or just keep a global pool
_redis_conn = None
_app = None

def _get_workflow():
    workflow = StateGraph(AgentState)
    workflow.add_node("agent", call_model)
    workflow.add_node("tools", execute_tools)
    workflow.add_node("evaluate", evaluate_context)
    workflow.add_node("web_search", web_search_fallback)

    workflow.add_edge(START, "agent")
    workflow.add_conditional_edges("agent", should_continue, ["tools", END])
    workflow.add_edge("tools", "evaluate")
    workflow.add_conditional_edges("evaluate", route_evaluation, ["agent", "web_search"])
    workflow.add_edge("web_search", "agent")
    
    return workflow

class AgentState(TypedDict):
    messages: Annotated[Sequence[BaseMessage], add_messages]
    tenant_id: str
    context_relevance: str

def get_tools() -> list:
    config = get_config()
    return [
        {
            "type": "function",
            "function": {
                "name": "search_vectors",
                "description": "Search for semantically similar text chunks in the vector database.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query_text": {
                            "type": "string",
                            "description": "The text to search for."
                        },
                        "limit": {
                            "type": "integer",
                            "description": f"Maximum number of results to return (default {config.default_search_limit})."
                        }
                    },
                    "required": ["query_text"]
                }
            }
        },
        {
            "type": "function",
            "function": {
                "name": "query_graph",
                "description": "Query the knowledge graph starting from a specific entity.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "entity_name": {
                            "type": "string",
                            "description": "The name of the entity to start the traversal from."
                        },
                        "max_hops": {
                            "type": "integer",
                            "description": f"Maximum number of relationship hops (default {config.default_max_hops})."
                        }
                    },
                    "required": ["entity_name"]
                }
            }
        }
    ]

def _execute_single_tool(tool_name: str, tool_input: dict, tenant_id: str) -> Tuple[List[Any], List[Any]]:
    config = get_config()
    if tool_name == "search_vectors":
        limit = int(tool_input.get("limit", config.default_search_limit))
        return search_vectors(tool_input["query_text"], limit=limit, tenant_id=tenant_id), []
    elif tool_name == "query_graph":
        max_hops = int(tool_input.get("max_hops", config.default_max_hops))
        return [], query_graph(tool_input["entity_name"], max_hops=max_hops, tenant_id=tenant_id)
    return [], []

def _build_context_string(merged_results: List[Any]) -> str:
    """Build a formatted context string from fused results."""
    context_parts = []
    for i, res in enumerate(merged_results, 1):
        source_info = " and ".join(res.sources)
        payload_str = str(res.payload)
        context_parts.append(f"[Result {i} (from {source_info})]: {payload_str}")

    return "\n".join(context_parts)

# --- LangGraph Nodes ---

async def call_model(state: AgentState):
    """The AI Agent node that decides what to do."""
    messages = state["messages"]
    
    config = get_config()
    llm = ChatOpenAI(
        model=config.llm_model_name,
        temperature=0,
        **config.get_llm_client_args()
    )
    
    # Bind our raw JSON schema tools to the model
    llm_with_tools = llm.bind_tools(get_tools())
    
    response = await llm_with_tools.ainvoke(messages)
    return {"messages": [response]}


async def execute_tools(state: AgentState):
    """The Tool execution node that runs DB queries and merges them."""
    messages = state["messages"]
    tenant_id = state["tenant_id"]
    
    # The last message is the AIMessage containing tool calls
    last_message = messages[-1]
    
    tool_messages = []
    vector_hits = []
    graph_hits = []
    
    for tool_call in last_message.tool_calls:
        tool_name = tool_call["name"]
        tool_input = tool_call["args"]
        tool_call_id = tool_call["id"]
        
        logger.info(f"LangGraph Agent called tool: {tool_name} with args: {tool_input}")
        
        # Run synchronous DB calls in threadpool
        loop = asyncio.get_running_loop()
        v_hits, g_hits = await loop.run_in_executor(None, _execute_single_tool, tool_name, tool_input, tenant_id)
        
        vector_hits.extend(v_hits)
        graph_hits.extend(g_hits)
        
        # We don't return the raw DB output to the LLM directly as it's unranked.
        # We will merge it later, but we need to satisfy LangChain's ToolMessage requirement
        tool_messages.append(
            ToolMessage(
                content="Executed tool. Results are being fused.",
                tool_call_id=tool_call_id
            )
        )
        
    # Merge and rank the results
    merged = merge_rank(vector_hits, graph_hits)
    context_str = _build_context_string(merged)
    
    if not context_str:
        context_str = "No results found."
        
    # We inject the synthesized context back as a system-like human message to force grounding
    grounding_message = HumanMessage(
        content=(
            f"Here is the context retrieved from the database:\n{context_str}\n\n"
        )
    )
    
    return {"messages": tool_messages + [grounding_message]}

class GradeDocuments(BaseModel):
    """Binary score for relevance check on retrieved documents."""
    binary_score: str = Field(
        description="Documents are relevant to the question, 'yes' or 'no'"
    )

async def evaluate_context(state: AgentState):
    """Grades the context retrieved by tools against the user's query."""
    messages = state["messages"]
    
    # Original user query
    user_query = messages[0].content
    
    # The last message is the HumanMessage with the retrieved context
    last_message = messages[-1]
    
    # Only evaluate if the last message actually contains context (defensive check)
    if not isinstance(last_message, HumanMessage) or "Here is the context retrieved from the database" not in last_message.content:
        return {"context_relevance": "no"}

    context_str = last_message.content
    
    # If the DB returned nothing
    if "No results found." in context_str:
        logger.info("CRAG: No DB results found. Grading as irrelevant.")
        return {"context_relevance": "no"}
        
    logger.info("CRAG: Evaluating retrieved context...")
    
    config = get_config()
    llm = ChatOpenAI(model=config.llm_model_name, temperature=0, **config.get_llm_client_args())
    structured_llm_grader = llm.with_structured_output(GradeDocuments)
    
    system = """You are a grader assessing relevance of a retrieved document to a user question. \n 
    It does not need to be a stringent test. The goal is to filter out erroneous retrievals. \n
    If the document contains keyword(s) or semantic meaning related to the user question, grade it as relevant. \n
    Give a binary score 'yes' or 'no' score to indicate whether the document is relevant to the question."""
    
    grade_prompt = f"{system}\n\nRetrieved document: \n\n {context_str} \n\n User question: {user_query}"
    
    try:
        res = await structured_llm_grader.ainvoke(grade_prompt)
        score = res.binary_score
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error(f"CRAG Evaluation failed: {e}. Defaulting to 'no'.")
        score = "no"
        
    logger.info(f"CRAG: Graded context relevance as '{score}'")
    return {"context_relevance": score}

def route_evaluation(state: AgentState) -> str:
    """Routes based on the evaluation grade."""
    score = state.get("context_relevance", "yes")
    if score == "yes":
        return "agent"
    return "web_search"

async def web_search_fallback(state: AgentState):
    """Fallback node that triggers SearXNG if the database context is insufficient."""
    logger.info("CRAG: Triggering Web Search Fallback via SearXNG...")
    messages = state["messages"]
    user_query = messages[0].content
    
    config = get_config()
    search_url = config.searxng_url
    
    try:
        # Perform asynchronous web search in thread
        loop = asyncio.get_running_loop()
        
        def _do_search():
            req = urllib.request.Request(
                f"{search_url}?q={urllib.parse.quote(user_query)}&format=json",
                headers={'User-Agent': 'VeraxiAgent/1.0'}
            )
            with urllib.request.urlopen(req) as response:
                return json.loads(response.read().decode())
                
        data = await loop.run_in_executor(None, _do_search)
        
        results = data.get("results", [])
        web_context = []
        for i, res in enumerate(results[:5], 1): # Top 5 hits
            web_context.append(f"[Web Result {i} ({res.get('url')})]: {res.get('content')}")
            
        context_str = "\n".join(web_context)
        if not context_str:
            context_str = "No web search results found."
            
        grounding_message = HumanMessage(
            content=(
                f"Web Search Fallback Context:\n{context_str}\n\n"
                f"Please provide your final answer based strictly on the above context."
            )
        )
        return {"messages": [grounding_message]}
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error(f"CRAG Web Search failed: {e}")
        return {"messages": [HumanMessage(content="Web search fallback failed. Please provide your final answer based on your internal knowledge or admit lack of context.")]}


def should_continue(state: AgentState) -> str:
    """Router that determines if we need to call tools or if we are done."""
    messages = state["messages"]
    last_message = messages[-1]
    
    # If the LLM made a tool call, route to tools
    if last_message.tool_calls:
        return "tools"
    
    # Otherwise, we are done
    return END


async def answer_question(question: str, tenant_id: str = "default", thread_id: str = "default", return_context: bool = False) -> str | Tuple[str, str]:
    """
    Executes the LangGraph state machine.
    Maintains conversation memory per thread_id.
    """
    config_obj = get_config()
    config = {"configurable": {"thread_id": thread_id}}
    
    initial_state = {
        "messages": [HumanMessage(content=question)],
        "tenant_id": tenant_id
    }
    
    logger.info(f"Starting async LangGraph run for thread_id={thread_id}")
    
    workflow = _get_workflow()
    
    # Run the graph asynchronously using context manager for memory
    async with AsyncRedisSaver.from_conn_string(config_obj.redis_url) as memory:
        app = workflow.compile(checkpointer=memory)
        final_state = await app.ainvoke(initial_state, config=config)
    
    # The final message is the AIMessage containing the answer
    final_answer = final_state["messages"][-1].content
    
    # Extract context (hacky extraction from the last human message if tools were called)
    context_str = ""
    if len(final_state["messages"]) > 2:
        # Find the last human message that contains "Here is the context retrieved"
        for msg in reversed(final_state["messages"]):
            if isinstance(msg, HumanMessage) and "Here is the context retrieved" in msg.content:
                context_str = msg.content.split("Here is the context retrieved from the database:\n")[1].split("\n\nPlease provide")[0]
                break
                
    if return_context:
        return final_answer, context_str
    return final_answer


from typing import AsyncGenerator

async def stream_answer_question(question: str, tenant_id: str = "default", thread_id: str = "default") -> AsyncGenerator[dict, None]:
    """
    Executes the LangGraph state machine and yields raw astream_events.
    """
    config_obj = get_config()
    config = {"configurable": {"thread_id": thread_id}}
    
    initial_state = {
        "messages": [HumanMessage(content=question)],
        "tenant_id": tenant_id
    }
    
    logger.info(f"Starting async streaming LangGraph run for thread_id={thread_id}")
    workflow = _get_workflow()
    
    async with AsyncRedisSaver.from_conn_string(config_obj.redis_url) as memory:
        app = workflow.compile(checkpointer=memory)
        async for event in app.astream_events(initial_state, config=config, version="v2"):
            yield event
