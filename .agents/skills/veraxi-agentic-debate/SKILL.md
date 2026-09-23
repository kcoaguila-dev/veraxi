---
name: veraxi-agentic-debate
description: Teaches the AI how to natively perform a multi-agent debate (STORM-style) for high-precision fact-checking using the Veraxi MCP tools.
---

# Veraxi Agentic Debate Workflow

When the user asks you to "aggressively fact-check" a claim, or requests an "agentic debate" on a topic, you should NOT just query the LLM's internal knowledge. Instead, you must act as a Multi-Agent system by executing the following 3-step loop yourself:

## Step 1: The Researcher (Data Gathering)
Use the `mcp_web_search` or `mcp_deep_research` tools from the Veraxi MCP server to gather raw data about the claim.
Do not proceed until you have raw, factual context.

## Step 2: The Writer (Drafting)
Write a private internal draft (in your thought block or scratchpad) that attempts to answer the user's query based **strictly** on the data you just retrieved.
You must cite the sources.

## Step 3: The Skeptic (Critique)
Review your own draft aggressively. 
- Did you hallucinate any details that weren't in the raw text? 
- Did you miss a nuance?
If the draft fails the critique, go back to Step 1 or 2 and fix it. 

## Final Output
Once the draft survives the Skeptic's critique, output the final verified answer to the user, explicitly stating that it was verified via the Agentic Debate workflow.
