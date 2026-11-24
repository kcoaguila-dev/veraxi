from backend.mcp_server.think_parser import ThinkTagStreamParser


def test_split_think_tags_across_chunk_boundaries():
    parser = ThinkTagStreamParser()
    chunks = ["Hello ", "<thi", "nk>step 1 ", "step 2</th", "ink>Final answer"]
    reasoning = []
    content = []
    ended = []

    for chunk in chunks:
        res = parser.feed_content(chunk)
        reasoning.extend(res.reasoning_deltas)
        content.extend(res.content_deltas)
        if res.reasoning_ended_ms is not None:
            ended.append(res.reasoning_ended_ms)

    flushed = parser.flush()
    reasoning.extend(flushed.reasoning_deltas)
    content.extend(flushed.content_deltas)

    assert "".join(reasoning) == "step 1 step 2"
    assert "".join(content) == "Hello Final answer"
    assert len(ended) == 1


def test_thought_tag_and_dangling_close_tag():
    parser = ThinkTagStreamParser()
    r1 = parser.feed_content("<thought>deep</thought>visible")
    assert r1.reasoning_deltas == ["deep"]
    assert r1.content_deltas == ["visible"]
    assert r1.reasoning_ended_ms is not None

    # Dangling close tag when thinking was disabled
    r2 = parser.feed_content("</think>plain")
    assert r2.reasoning_deltas == []
    assert r2.content_deltas == ["plain"]


def test_explicit_reasoning_content_transitions_cleanly():
    parser = ThinkTagStreamParser()
    r1 = parser.feed_explicit_reasoning("thinking part 1 ")
    assert r1.reasoning_deltas == ["thinking part 1 "]
    assert r1.reasoning_ended_ms is None

    r2 = parser.feed_content("answer")
    assert r2.reasoning_ended_ms is not None
    assert r2.content_deltas == ["answer"]
