import re
with open("backend/api_gateway.py", "r") as f:
    content = f.read()
    
# Extract list_threads function
match = re.search(r'async def list_threads\(.*?\):.*?(?=async def)', content, re.DOTALL)
if match:
    print(match.group(0))
else:
    print("Not found")
