import re
import time

def test_regex(pattern, text):
    start = time.time()
    re.sub(pattern, "", text)
    return time.time() - start

texts = [
    "![" + "a" * 100000 + "](",
    "![" + "a" * 100000 + "]",
    "[" + "a" * 100000 + "](",
    "<http" + "a" * 100000 + ">",
    "<https://" + "a" * 100000,
]

patterns = [
    r"!\[[^\]]*\]\([^)]*\)",
    r"\[([^\]]+)\]\([^)]*\)",
    r"<https?://[^>]+>"
]

for p in patterns:
    for t in texts:
        print(f"{p} on len {len(t)}: {test_regex(p, t):.5f}s")
