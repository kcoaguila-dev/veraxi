import re
import time

def check(p, text):
    start = time.time()
    try:
        re.sub(p, "", text)
    except Exception as e:
        print(f"Error: {e}")
    return time.time() - start

# Let's test the Polynomial regular expression used on uncontrolled data.
# 1: r"!\[[^\]]*\]\([^)]*\)"
# This uses `[^\]]*` and `[^)]*`. If there's backtracking, it's because there are overlapping paths or nested quantifiers.
# Wait, `[^\]]*` is a negated character class. CodeQL alerts on polynomial regex if it detects something like `a*b*a*` or `(a|b)*`.
# But `!\[[^\]]*\]\([^)]*\)` doesn't have nested quantifiers. Wait. What if there is `(a*)*`? No.
# Could it be `\s*` in ````(?:[\w+-]+)?\s*`? Yes, ````(?:[\w+-]+)?\s*` might be problematic.
# `[\w+-]+` and `\s*` might overlap if `\w` matches `\s`. `\w` is `[a-zA-Z0-9_]`. `\s` is whitespace. They do not overlap.
# Let's check `^\s*[-|:]{3,}\s*$`? `\s*` at start and `\s*` at end? Overlap with `[-|:]`? No.
# What about `\*{1,3}|_{1,3}|~~`? Overlaps? No.
# The user specified: 'Polynomial regular expression used on uncontrolled data" in backend/routes/tts.py (around lines 31-33).'
# lines 31-33 in tts.py are:
# 31: text = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", text)
# 32: text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)
# 33: text = re.sub(r"<https?://[^>]+>", "", text)

# Is `[^\]]*` polynomial? CodeQL sometimes alerts on `[^X]*` if not careful, but maybe because it can cause catastrophic backtracking if used with other elements?
# Actually, the fix for markdown links is to use non-greedy matching `.*?` instead of `[^\]]*`? Or better, `[^\]\r\n]*` to avoid crossing lines?
# In CodeQL, `[^\]]*` is considered polynomial if there is ambiguity, for instance if followed by something that can also match.
# Wait, let's just make it non-greedy and avoid polynomial behavior, or restrict it better.
# Or replace with something like `re.sub(r"!\[.*?\]\(.*?\)", "", text)`
