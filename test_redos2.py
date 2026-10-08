import re
import time
t = "![" + "a" * 100000 + "](b" * 100000
start = time.time()
re.sub(r"!\[[^\]]*\]\([^)]*\)", "", t)
print(time.time() - start)
