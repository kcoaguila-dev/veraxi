"""Citation-style regression tests for the web tool prompts.

The web_search and dynamic_web_graph tool docstrings instruct the LLM how
to cite sources. They must follow the canonical style from
``backend/prompts.py``: inline markdown links using the exact URL from the
tool output, with bare numeric citations (``[1]``) forbidden — never the
old "[Title] only, no hyperlinks" style.
"""

from backend.mcp_server.tools import dynamic_web_graph, web_search


def test_web_search_docstrings_use_canonical_citation_style():
    module_doc = web_search.__doc__ or ""
    fn_doc = web_search.mcp_web_search.__doc__ or ""

    for doc in (module_doc, fn_doc):
        assert "](http" in doc  # an inline markdown-link example is given
        assert "[1]" in doc  # bare numeric citations are called out as banned

    combined = module_doc + fn_doc
    assert "Do not use numbers" not in combined
    assert "NEVER use markdown hyperlinks" not in combined
    assert "Just use `[Title]`" not in combined
    assert "ONLY the source" not in combined


def test_dynamic_web_graph_docstring_uses_canonical_citation_style():
    fn_doc = dynamic_web_graph.mcp_dynamic_web_graph.__doc__ or ""

    assert "](http" in fn_doc  # an inline markdown-link example is given
    assert "[1]" in fn_doc  # bare numeric citations are called out as banned
    assert "containing ONLY" not in fn_doc
