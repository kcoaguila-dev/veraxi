import sys
import logging
from backend.mcp_server.llm_loop import answer_question

# Enable logging to see the LLM tool usage and provenance
logging.basicConfig(level=logging.INFO, format='%(levelname)s: %(message)s')

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python -m scripts.ask_veraxi 'Your question here'")
        sys.exit(1)
        
    question = " ".join(sys.argv[1:])
    print(f"\n🤔 Question: {question}\n")
    
    try:
        answer = answer_question(question)
        print("\n================ FINAL ANSWER ================\n")
        print(answer)
        print("\n==============================================\n")
    except Exception as e:
        print(f"\n❌ Error running MCP inference: {e}")
