import os


def list_artifacts(tenant_id: str) -> list[dict]:
    """
    Returns a list of available artifacts for the given tenant.
    """
    artifacts_dir = f"/app/backend/data/artifacts/{tenant_id}"
    
    if not os.path.exists(artifacts_dir):
        return []
        
    artifacts = []
    for filename in os.listdir(artifacts_dir):
        filepath = os.path.join(artifacts_dir, filename)
        if os.path.isfile(filepath):
            stats = os.stat(filepath)
            artifacts.append({
                "name": filename,
                "size_bytes": stats.st_size,
                "modified": stats.st_mtime
            })
            
    return artifacts

def read_artifact(tenant_id: str, artifact_name: str) -> str:
    """
    Reads the content of an artifact.
    """
    # Sanitize to prevent path traversal
    safe_name = os.path.basename(artifact_name)
    filepath = f"/app/backend/data/artifacts/{tenant_id}/{safe_name}"
    
    if not os.path.exists(filepath):
        return f"Artifact not found: {safe_name}"
        
    with open(filepath, 'r') as f:
        return f.read()
