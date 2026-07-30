import urllib.request
import json
try:
    req = urllib.request.Request("http://127.0.0.1:8000/api/chat/threads")
    with urllib.request.urlopen(req) as response:
        print("Response:", response.read().decode())
except Exception as e:
    print("Error:", e)
