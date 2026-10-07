import re
import time

def test_regex(pattern, text):
    start = time.time()
    try:
        re.sub(pattern, "", text)
    except Exception:
        pass
    return time.time() - start

# To cause ReDoS, we usually need something like nested quantifiers or overlapping alternation.
# Wait, look at:
# text = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", text)
# text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)
# text = re.sub(r"<https?://[^>]+>", "", text)

# Is there catastrophic backtracking?
# Wait, what if we use string without matching end?
