import re
import time

def check(p, text):
    start = time.time()
    try:
        re.sub(p, "", text)
    except Exception as e:
        print(f"Error: {e}")
    return time.time() - start

# Markdown link format regex testing
p1 = r"!\[[^\]]*\]\([^)]*\)"
p2 = r"\[([^\]]+)\]\([^)]*\)"
p3 = r"<https?://[^>]+>"

text = "![" + "]" * 100000
print(f"p1: {check(p1, text):.5f}")

text = "[" + "]" * 100000
print(f"p2: {check(p2, text):.5f}")
