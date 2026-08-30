import requests
import json

url = "http://localhost:8000/api/chat"
headers = {"Content-Type": "application/json"}
payload = {
    "question": "Whos trump?",
    "stream": False,
    "model": "gemini-2.5-flash-lite",
    "tool_settings": {"file_search_enabled": False}
}

try:
    response = requests.post(url, json=payload)
    print(response.text[:200])
except Exception as e:
    print(f"Error: {e}")
