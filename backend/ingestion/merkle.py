"""Content-addressed Merkle tree helpers for incremental & shared repo indexing."""

from __future__ import annotations

import hashlib
from pathlib import Path


def _hash_file_bytes(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def compute_repo_merkle(
    root_path: Path, files: list[Path]
) -> tuple[str, dict[str, str]]:
    """Compute per-file SHA-256 hashes and a deterministic Merkle root."""
    file_hashes: dict[str, str] = {}
    for path in files:
        try:
            rel = path.relative_to(root_path).as_posix()
            file_hashes[rel] = _hash_file_bytes(path)
        except OSError:
            continue

    root_hasher = hashlib.sha256()
    for rel in sorted(file_hashes):
        root_hasher.update(f"{rel}:{file_hashes[rel]}\n".encode())
    return root_hasher.hexdigest(), file_hashes


def diff_merkle_hashes(
    old_hashes: dict[str, str], new_hashes: dict[str, str]
) -> set[str]:
    """Return relative paths that were added, modified, or deleted."""
    changed: set[str] = set()
    all_paths = set(old_hashes) | set(new_hashes)
    for rel in all_paths:
        if old_hashes.get(rel) != new_hashes.get(rel):
            changed.add(rel)
    return changed
