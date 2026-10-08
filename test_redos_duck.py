import urllib.request, urllib.parse
query = "CodeQL Polynomial regular expression used on uncontrolled data regex markdown link python"
url = f"https://html.duckduckgo.com/html/?q={urllib.parse.quote(query)}"
req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
html = urllib.request.urlopen(req).read().decode("utf-8")
import re
for m in re.finditer(r"<a class=\"result__snippet[^>]*>(.*?)</a>", html):
    print(re.sub(r"<[^>]+>", "", m.group(1)))
