import os

files = [
    "backend/mcp_server/formatter.py",
    "backend/mcp_server/orchestrator.py",
    "backend/mcp_server/tools/web_browser.py",
    "backend/pyproject.toml",
    "backend/routes/admin.py",
    "backend/routes/sync.py"
]

for f in files:
    if os.path.exists(f):
        print(f"=== {f} ===")
        with open(f, "r") as fp:
            lines = fp.readlines()
            in_conflict = False
            for line in lines:
                if line.startswith("<<<<<<<"):
                    in_conflict = True
                if in_conflict:
                    print(line, end="")
                if line.startswith(">>>>>>>"):
                    in_conflict = False
                    print("-" * 40)
