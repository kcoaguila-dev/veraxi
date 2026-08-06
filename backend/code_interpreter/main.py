from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import subprocess
import tempfile
import os

app = FastAPI()

class CodeExecutionRequest(BaseModel):
    code: str
    timeout: int = 10

class CodeExecutionResponse(BaseModel):
    stdout: str
    stderr: str
    exit_code: int

@app.post("/execute", response_model=CodeExecutionResponse)
async def execute_code(req: CodeExecutionRequest):
    # Security: This runs as whatever user the container runs as.
    # In a real production setup with LibreChat, they use NsJail or libkrun.
    # For this implementation, we rely on the Docker container isolation.
    try:
        with tempfile.NamedTemporaryFile(mode='w', suffix='.py', delete=False) as f:
            f.write(req.code)
            temp_path = f.name
            
        result = subprocess.run(
            ["python", temp_path],
            capture_output=True,
            text=True,
            timeout=req.timeout
        )
        
        return CodeExecutionResponse(
            stdout=result.stdout,
            stderr=result.stderr,
            exit_code=result.returncode
        )
    except subprocess.TimeoutExpired as e:
        return CodeExecutionResponse(
            stdout=e.stdout.decode('utf-8') if e.stdout else "",
            stderr=e.stderr.decode('utf-8') if e.stderr else f"Execution timed out after {req.timeout} seconds.",
            exit_code=-1
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        if os.path.exists(temp_path):
            os.remove(temp_path)
