import os
from pathlib import Path


def init_project(force: bool = False):
    """
    Initializes project by auto-generating/appending CLAUDE.md and .cursorrules.
    """
    cwd = Path(os.getcwd())

    claude_md_path = cwd / "CLAUDE.md"
    cursorrules_path = cwd / ".cursorrules"

    claude_content = """# AI Agent Instructions for Veraxi Knowledge Graph
When researching architecture, domain concepts, or prior investigations in this project, use the Veraxi MCP tools (`mcp_build_lazy_dossier`, `mcp_query_graph`) before writing or modifying code.
"""

    cursorrules_content = """# Veraxi Knowledge Graph Rules
- Always verify domain assertions against Veraxi knowledge tools when available.
"""

    def _ensure_content(file_path: Path, content: str):
        if not file_path.exists() or force:
            file_path.write_text(content)
            print(f"Created {file_path.name}")
        else:
            existing_content = file_path.read_text()
            if content.strip() not in existing_content:
                # Append cleanly
                if not existing_content.endswith("\n"):
                    file_path.write_text(existing_content + "\n" + content)
                else:
                    file_path.write_text(existing_content + content)
                print(f"Updated {file_path.name}")
            else:
                print(f"{file_path.name} already contains Veraxi rules")

    _ensure_content(claude_md_path, claude_content)
    _ensure_content(cursorrules_path, cursorrules_content)
