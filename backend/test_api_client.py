import urllib.request
import json

req = urllib.request.Request("http://127.0.0.1:8000/api/chat/threads", headers={
    'Cache-Control': 'no-cache, no-store, must-revalidate',
    'Pragma': 'no-cache',
    'Expires': '0'
})
with urllib.request.urlopen(req) as response:
    print(response.read().decode())
