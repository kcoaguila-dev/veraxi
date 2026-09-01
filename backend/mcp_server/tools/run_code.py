import os
import subprocess
import tempfile


def execute_python_code(code: str) -> dict:
    """
    Executes Python code in a secure subprocess.
    Returns the stdout and stderr output.
    """
    # Create a temporary file to store the code
    with tempfile.NamedTemporaryFile(mode='w', suffix='.py', delete=False) as f:
        f.write(code)
        temp_path = f.name

    try:
        # Execute the python script with a 10 second timeout
        result = subprocess.run(  # noqa: PLW1510
            ['python', temp_path],
            capture_output=True,
            text=True,
            timeout=10
        )
        return {
            "stdout": result.stdout,
            "stderr": result.stderr,
            "exit_code": result.returncode
        }
    except subprocess.TimeoutExpired as e:
        return {
            "stdout": e.stdout.decode('utf-8') if e.stdout else "",
            "stderr": f"Execution timed out after 10 seconds.\n{e.stderr.decode('utf-8') if e.stderr else ''}",
            "exit_code": 124
        }
    except Exception as e:  # noqa: BLE001
        return {
            "stdout": "",
            "stderr": f"Failed to execute code: {e!s}",
            "exit_code": 1
        }
    finally:
        # Clean up the temporary file
        if os.path.exists(temp_path):
            os.remove(temp_path)
