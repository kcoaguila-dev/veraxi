import re
import time
texts = [
    "```" + "a" * 100000 + "!",
    "![" + "a" * 100000 + "](",
    "[" + "a" * 100000 + "](",
    "<http" + "a" * 100000 + ">",
]
regexes = [
    r"```(?:[\w+-]+)?\s*",
    r"`([^`]+)`",
    r"!\[[^\]]*\]\([^)]*\)",
    r"\[([^\]]+)\]\([^)]*\)",
    r"<https?://[^>]+>"
]

for r in regexes:
    for t in texts:
        start = time.time()
        re.sub(r, "", t)
        print(f"{r} on {t[:10]}... took {time.time() - start:.5f}s")
