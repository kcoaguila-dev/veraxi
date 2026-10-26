import json
import os
import sys
import urllib.request
import urllib.error
from pathlib import Path


def _upload_file(filepath: Path, endpoint: str, key: str | None):
    try:
        with open(filepath, 'rb') as f:
            file_data = f.read()
    except Exception as e:
        print(f"Error reading {filepath}: {e}", file=sys.stderr)
        return

    # Basic multipart form-data construction using standard library
    boundary = "----VeraxiFormBoundary1234567890"
    filename = filepath.name

    # We construct the multipart body
    body = bytearray()
    body.extend(f"--{boundary}\r\n".encode("utf-8"))
    body.extend(f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'.encode("utf-8"))
    body.extend(b"Content-Type: application/octet-stream\r\n\r\n")
    body.extend(file_data)
    body.extend(f"\r\n--{boundary}--\r\n".encode("utf-8"))

    req = urllib.request.Request(f"{endpoint}/api/admin/ingest/upload", data=body)
    req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
    if key:
        req.add_header("Authorization", f"Bearer {key}")

    try:
        print(f"Uploading {filename}...", end=" ", flush=True)
        with urllib.request.urlopen(req, timeout=30) as response:
            status = response.getcode()
            print(f"[{status} OK] Ingested into knowledge graph")
    except urllib.error.HTTPError as e:
        print(f"[{e.code} Error] {e.reason}", file=sys.stderr)
    except Exception as e:
        print(f"[Error] {e}", file=sys.stderr)


def _ingest_url(url: str, endpoint: str, key: str | None):
    data = json.dumps({"url": url}).encode("utf-8")
    req = urllib.request.Request(f"{endpoint}/api/admin/ingest/url", data=data)
    req.add_header("Content-Type", "application/json")
    if key:
        req.add_header("Authorization", f"Bearer {key}")

    try:
        print(f"Ingesting URL {url}...", end=" ", flush=True)
        with urllib.request.urlopen(req, timeout=30) as response:
            status = response.getcode()
            print(f"[{status} OK] Ingested into knowledge graph")
    except urllib.error.HTTPError as e:
        print(f"[{e.code} Error] {e.reason}", file=sys.stderr)
    except Exception as e:
        print(f"[Error] {e}", file=sys.stderr)


def run_ingest(
    target: str,
    key: str | None = None,
    endpoint: str = "http://localhost:8000",
):
    """
    CLI Document & URL Ingest
    """
    # Remove trailing slash from endpoint if present
    if endpoint.endswith('/'):
        endpoint = endpoint[:-1]

    if target.startswith("http://") or target.startswith("https://"):
        _ingest_url(target, endpoint, key)
    else:
        path = Path(target)
        if not path.exists():
            print(f"Error: Path {target} does not exist.", file=sys.stderr)
            sys.exit(1)

        allowed_extensions = {".md", ".txt", ".pdf", ".py", ".dart"}

        if path.is_file():
            if path.suffix in allowed_extensions:
                _upload_file(path, endpoint, key)
            else:
                print(f"Skipping {path.name}: Unsupported extension.", file=sys.stderr)
        elif path.is_dir():
            files_to_upload = []
            for root, _, files in os.walk(path):
                for f in files:
                    filepath = Path(root) / f
                    if filepath.suffix in allowed_extensions:
                        files_to_upload.append(filepath)

            if not files_to_upload:
                print(f"No supported files found in {target}.")
                return

            for filepath in files_to_upload:
                _upload_file(filepath, endpoint, key)
