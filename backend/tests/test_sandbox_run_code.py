"""Tests for zero-trust sandboxed Python code execution."""

from backend.mcp_server.tools.run_code import execute_python_code


def test_sandbox_pure_python_success():
    code = """
import math
import json

data = {"result": math.sqrt(144), "items": [1, 2, 3]}
print("OUTPUT_JSON:" + json.dumps(data))
"""
    res = execute_python_code(code)
    assert res["exit_code"] == 0
    assert 'OUTPUT_JSON:{"result": 12.0, "items": [1, 2, 3]}' in res["stdout"]
    assert res["stderr"] == ""


def test_sandbox_blocks_socket_networking():
    code = """
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.connect(("127.0.0.1", 80))
"""
    res = execute_python_code(code)
    assert res["exit_code"] != 0
    assert "Network access is forbidden in sandbox" in res["stderr"]


def test_sandbox_blocks_subprocess_popen():
    code = """
import subprocess
subprocess.run(["ls", "-la"])
"""
    res = execute_python_code(code)
    assert res["exit_code"] != 0
    assert "Process execution is forbidden in sandbox" in res["stderr"]


def test_sandbox_blocks_os_system():
    code = """
import os
os.system("echo hacked")
"""
    res = execute_python_code(code)
    assert res["exit_code"] != 0
    assert "Process execution is forbidden in sandbox" in res["stderr"]


def test_sandbox_blocks_sensitive_file_read():
    code = """
with open("/etc/passwd", "r") as f:
    data = f.read()
"""
    res = execute_python_code(code)
    assert res["exit_code"] != 0
    assert "sensitive resource forbidden" in res["stderr"]


def test_sandbox_blocks_arbitrary_file_write_outside_sandbox():
    code = """
with open("/tmp/veraxi_unauthorized_probe.txt", "w") as f:
    f.write("bad")
"""
    res = execute_python_code(code)
    assert res["exit_code"] != 0
    assert "Write access outside sandbox forbidden" in res["stderr"]


def test_sandbox_blocks_directory_listing_outside_sandbox():
    code = """
import os
files = os.listdir("/")
"""
    res = execute_python_code(code)
    assert res["exit_code"] != 0
    assert "Directory listing outside sandbox forbidden" in res["stderr"]


def test_sandbox_blocks_reading_host_app_files_outside_whitelist():
    code = """
import os
with open("/home/ubuntu/src/ai/veraxi/backend/config.py", "r") as f:
    text = f.read()
"""
    res = execute_python_code(code)
    assert res["exit_code"] != 0
    assert "Read access outside sandbox forbidden" in res["stderr"]


def test_sandbox_handles_timeout():
    code = """
import time
while True:
    time.sleep(0.1)
"""
    # 2 second timeout for rapid test
    res = execute_python_code(code, timeout=2)
    assert res["exit_code"] == 124
    assert "timed out" in res["stderr"].lower()
