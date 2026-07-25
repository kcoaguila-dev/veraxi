import sys
import logging
from backend.mcp_server.llm_loop import answer_question

# Enable logging to see the LLM tool usage and provenance
logging.basicConfig(level=logging.INFO, format="%(asctime)s | %(levelname)s: %(message)s", datefmt="%H:%M:%S")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        logging.error("Usage: python -m scripts.ask_veraxi 'Your question here'")
        sys.exit(1)

    question = " ".join(sys.argv[1:])
    logging.info(f"Question: {question}\n")

    try:
        answer = answer_question(question)
        logging.info("\n================ FINAL ANSWER ================\n")
        logging.info(answer)
        logging.info("\n==============================================\n")
    except Exception as e:
        logging.exception("❌ Error running MCP inference")
        sys.exit(1)
