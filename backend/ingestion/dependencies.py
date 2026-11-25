"""Dependency extraction from package manifests.

Pure parsers for the three manifest formats used in this repo's
ecosystems:

* ``pyproject.toml`` — stdlib ``tomllib``; reads
  ``project.dependencies`` / ``project.optional-dependencies`` plus
  conservative Poetry tables (``tool.poetry.dependencies`` and
  ``tool.poetry.group.*.dependencies``).
* ``package.json`` — stdlib ``json``; ``dependencies`` +
  ``devDependencies``.
* ``pubspec.yaml`` — PyYAML (already a declared backend dependency in
  ``pyproject.toml``); ``dependencies`` + ``dev_dependencies``.

Each parser returns a list of dicts::

    {"name": str, "version": str | None, "version_spec": str,
     "spec_kind": str, "ecosystem": str, "source_file": str}

Version-spec handling is conservative (fail closed, mirroring the
vuln-intel version comparator):

* an exact pin (``1.2.3``, ``==1.2.3``, ``=1.2.3``) yields that version
  with ``spec_kind="exact"``;
* a ranged spec (``^``, ``~``, ``>=`` …) yields the minimum/base
  version it names with ``spec_kind`` of ``"caret"`` / ``"tilde"`` /
  ``"range"`` — downstream matching treats that base as the installed
  version, which is the lowest version the spec allows;
* anything unparseable (``*``, ``any``, git/path URLs, complex
  compound specifiers with no extractable base) yields
  ``version=None`` and ``spec_kind="unknown"`` so the join can mark
  the match ``unknown`` instead of guessing.
"""

from __future__ import annotations

import json
import logging
import os
import re
import tomllib
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

MANIFEST_NAMES = ("pyproject.toml", "package.json", "pubspec.yaml", "uv.lock", "package-lock.json")
_SKIPPED_DIRS = {
    "node_modules",
    "vendor",
    ".git",
    "dist",
    "build",
    "__pycache__",
    ".venv",
    "venv",
    "env",
    ".tox",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    ".dart_tool",
}

_VERSION_TOKEN = re.compile(r"^\d+(?:\.\d+)*$")
_SPEC_BASE = re.compile(r"(\d+(?:\.\d+)*)")


def normalize_package_name(name: str, ecosystem: str = "") -> str:
    """Canonical package name for cross-source comparison.

    Python names follow PEP 503 (lowercase, runs of ``-_.`` collapse to
    ``-``); CPE product names use ``_`` where PyPI uses ``-``, so the
    same normalization is applied for every ecosystem to let the vuln
    join compare them safely. Scoped npm names keep their ``@scope/``
    prefix (lowercased only).
    """
    cleaned = (name or "").strip().lower()
    if ecosystem == "npm" and "/" in cleaned:
        return cleaned
    return re.sub(r"[-_.]+", "-", cleaned)


def _concrete_version(token: str) -> str | None:
    token = token.strip().strip(",").strip()
    return token if _VERSION_TOKEN.match(token) else None


def parse_version_spec(spec: str) -> tuple[str | None, str]:
    """Extract a concrete/base version and spec kind from a spec string.

    Returns ``(version, spec_kind)``; ``version`` is ``None`` when no
    trustworthy version can be extracted (fail closed).
    """
    text = (spec or "").strip()
    if not text or text in ("*", "any", "latest"):
        return None, "unknown"
    if text.startswith(("git+", "git:", "http://", "https://", "file:", "path:")):
        return None, "unknown"
    if text.startswith("^"):
        version = _concrete_version(text[1:])
        return (version, "caret") if version else (None, "unknown")
    if text.startswith("~="):
        version = _concrete_version(text[2:].split(" ")[0].split(",")[0])
        return (version, "tilde") if version else (None, "unknown")
    if text.startswith("~"):
        version = _concrete_version(text[1:].split(" ")[0])
        return (version, "tilde") if version else (None, "unknown")
    if text.startswith("=="):
        version = _concrete_version(text[2:].split(";")[0].split(" ")[0])
        return (version, "exact") if version else (None, "unknown")
    if text.startswith("=") and not text.startswith(">="):
        version = _concrete_version(text[1:])
        return (version, "exact") if version else (None, "unknown")
    if text[0].isdigit():
        version = _concrete_version(text.split(" ")[0])
        return (version, "exact") if version else (None, "unknown")
    # Ranged / compound specifiers (>=, <=, <, >, !=, comma/space lists):
    # take the first version token as the minimum/base version.
    match = _SPEC_BASE.search(text)
    if match:
        return match.group(1), "range"
    return None, "unknown"


def _record(
    name: str, spec: str, ecosystem: str, source_file: str
) -> dict[str, Any]:
    version, spec_kind = parse_version_spec(spec)
    return {
        "name": name,
        "version": version,
        "version_spec": spec,
        "spec_kind": spec_kind,
        "ecosystem": ecosystem,
        "source_file": source_file,
    }


# ---------------------------------------------------------------------------
# pyproject.toml (PEP 621 + Poetry)
# ---------------------------------------------------------------------------

_PEP508_NAME = re.compile(r"^\s*([A-Za-z0-9][A-Za-z0-9._-]*)\s*(?:\[[^\]]*\])?\s*(.*)$")


def _parse_pep508(entry: str, source_file: str) -> dict[str, Any] | None:
    match = _PEP508_NAME.match(entry)
    if not match:
        return None
    name, rest = match.group(1), (match.group(2) or "").strip()
    if rest.startswith("(") and rest.endswith(")"):
        rest = rest[1:-1].strip()
    # Direct references (name @ url) carry no trustworthy version.
    if rest.startswith("@"):
        return {
            "name": name,
            "version": None,
            "version_spec": rest,
            "spec_kind": "unknown",
            "ecosystem": "pypi",
            "source_file": source_file,
        }
    spec = rest.split(";")[0].strip()
    return _record(name, spec if spec else "", "pypi", source_file)


def _unknown_record(
    name: str, ecosystem: str, source_file: str, version_spec: str = ""
) -> dict[str, Any]:
    return {
        "name": name,
        "version": None,
        "version_spec": version_spec,
        "spec_kind": "unknown",
        "ecosystem": ecosystem,
        "source_file": source_file,
    }


def _parse_poetry_value(
    name: str, value: Any, source_file: str
) -> list[dict[str, Any]]:
    if isinstance(value, str):
        return [_record(name, value, "pypi", source_file)]
    if isinstance(value, dict):
        version = value.get("version")
        if isinstance(version, str):
            return [_record(name, version, "pypi", source_file)]
        return [_unknown_record(name, "pypi", source_file)]
    if isinstance(value, list):
        return [
            _record(name, item["version"], "pypi", source_file)
            for item in value
            if isinstance(item, dict) and isinstance(item.get("version"), str)
        ]
    return []


def _poetry_entries(table: Any, source_file: str) -> list[dict[str, Any]]:
    if not isinstance(table, dict):
        return []
    records: list[dict[str, Any]] = []
    for name, value in table.items():
        if name == "python":
            continue
        records.extend(_parse_poetry_value(name, value, source_file))
    return records


def _parse_pep508_list(entries: Any, source_file: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for entry in entries or []:
        if not isinstance(entry, str):
            continue
        record = _parse_pep508(entry, source_file)
        if record is not None:
            records.append(record)
    return records


def parse_pyproject_text(text: str, source_file: str = "pyproject.toml") -> list[dict[str, Any]]:
    """Parse dependency records out of ``pyproject.toml`` text."""
    try:
        data = tomllib.loads(text)
    except tomllib.TOMLDecodeError as exc:
        logger.warning("Unparseable pyproject %s: %s", source_file, exc)
        return []
    project = data.get("project") or {}
    records = _parse_pep508_list(project.get("dependencies"), source_file)
    for group in (project.get("optional-dependencies") or {}).values():
        records.extend(_parse_pep508_list(group, source_file))
    poetry = (data.get("tool") or {}).get("poetry") or {}
    records.extend(_poetry_entries(poetry.get("dependencies"), source_file))
    for group in (poetry.get("group") or {}).values():
        if isinstance(group, dict):
            records.extend(_poetry_entries(group.get("dependencies"), source_file))
    return records


# ---------------------------------------------------------------------------
# package.json
# ---------------------------------------------------------------------------


def parse_package_json_text(text: str, source_file: str = "package.json") -> list[dict[str, Any]]:
    """Parse dependency records out of ``package.json`` text."""
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        logger.warning("Unparseable package.json %s: %s", source_file, exc)
        return []
    records: list[dict[str, Any]] = []
    for section in ("dependencies", "devDependencies"):
        table = data.get(section) or {}
        if not isinstance(table, dict):
            continue
        for name, spec in table.items():
            if isinstance(spec, str):
                records.append(_record(name, spec, "npm", source_file))
    return records


# ---------------------------------------------------------------------------
# pubspec.yaml (PyYAML is a declared backend dependency)
# ---------------------------------------------------------------------------


def _parse_pubspec_entry(
    name: str, value: Any, source_file: str
) -> dict[str, Any] | None:
    if isinstance(value, str):
        return _record(name, value, "pub", source_file)
    if isinstance(value, dict):
        version = value.get("version")
        if isinstance(version, str):
            return _record(name, version, "pub", source_file)
        # sdk:/git:/path: hosted-less entries — no version.
        return _unknown_record(name, "pub", source_file)
    return None


def parse_pubspec_text(text: str, source_file: str = "pubspec.yaml") -> list[dict[str, Any]]:
    """Parse dependency records out of ``pubspec.yaml`` text."""
    import yaml

    try:
        data = yaml.safe_load(text) or {}
    except yaml.YAMLError as exc:
        logger.warning("Unparseable pubspec %s: %s", source_file, exc)
        return []
    records: list[dict[str, Any]] = []
    for section in ("dependencies", "dev_dependencies"):
        table = data.get(section) or {}
        if not isinstance(table, dict):
            continue
        for name, value in table.items():
            record = _parse_pubspec_entry(name, value, source_file)
            if record is not None:
                records.append(record)
    return records


def parse_uv_lock_text(
    text: str, source_file: str = "uv.lock"
) -> list[dict[str, Any]]:
    """Parse ``[[package]]`` entries from a ``uv.lock`` file."""
    try:
        data = tomllib.loads(text)
    except tomllib.TOMLDecodeError as exc:
        logger.warning("Invalid TOML in %s: %s", source_file, exc)
        return []
    packages = data.get("package")
    if not isinstance(packages, list):
        return []
    records: list[dict[str, Any]] = []
    for pkg in packages:
        if not isinstance(pkg, dict):
            continue
        source = pkg.get("source")
        if isinstance(source, dict) and ("editable" in source or "virtual" in source):
            continue
        name = pkg.get("name")
        version = pkg.get("version")
        if not isinstance(name, str) or not isinstance(version, str) or not version:
            continue
        records.append(
            {
                "name": normalize_package_name(name, "pypi"),
                "version": version,
                "version_spec": f"=={version}",
                "spec_kind": "exact",
                "ecosystem": "pypi",
                "source_file": source_file,
            }
        )
    return records


def parse_package_lock_text(
    text: str, source_file: str = "package-lock.json"
) -> list[dict[str, Any]]:
    """Parse locked npm packages from a ``package-lock.json`` file."""
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        logger.warning("Invalid JSON in %s: %s", source_file, exc)
        return []
    if not isinstance(data, dict):
        return []
    records: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()
    packages = data.get("packages")
    if isinstance(packages, dict):
        for pkg_path, info in packages.items():
            if not pkg_path or "node_modules/" not in pkg_path or not isinstance(info, dict):
                continue
            name = pkg_path.rsplit("node_modules/", 1)[-1]
            version = info.get("version")
            if not isinstance(version, str) or not version:
                continue
            norm = normalize_package_name(name, "npm")
            if (norm, version) in seen:
                continue
            seen.add((norm, version))
            records.append(
                {
                    "name": norm,
                    "version": version,
                    "version_spec": version,
                    "spec_kind": "exact",
                    "ecosystem": "npm",
                    "source_file": source_file,
                }
            )
    return records


# ---------------------------------------------------------------------------
# Language-agnostic SBOM (CycloneDX & SPDX JSON)
# ---------------------------------------------------------------------------

_PURL_ECOSYSTEM_MAP = {
    "pypi": "pypi",
    "npm": "npm",
    "maven": "maven",
    "golang": "go",
    "go": "go",
    "cargo": "crates.io",
    "pub": "pub",
    "nuget": "nuget",
    "gem": "rubygems",
    "composer": "packagist",
    "deb": "debian",
    "apk": "alpine",
    "rpm": "rpm",
}


def _parse_purl(purl: str) -> tuple[str, str, str | None] | None:
    """Parse a Package URL (``pkg:type/[ns/]name@version``) into ``(ecosystem, name, version)``."""
    if not purl or not purl.startswith("pkg:"):
        return None
    from urllib.parse import unquote

    body = purl[4:].split("#", 1)[0].split("?", 1)[0]
    if "/" not in body:
        return None
    purl_type, rest = body.split("/", 1)
    ecosystem = _PURL_ECOSYSTEM_MAP.get(purl_type.lower(), purl_type.lower())
    version: str | None = None
    if "@" in rest:
        rest, raw_ver = rest.rsplit("@", 1)
        version = unquote(raw_ver) or None
    parts = [unquote(p) for p in rest.split("/") if p]
    if not parts:
        return None
    if ecosystem == "maven" and len(parts) >= 2:
        name = f"{parts[-2]}:{parts[-1]}"
    elif ecosystem == "npm" and len(parts) >= 2 and parts[-2].startswith("@"):
        name = f"{parts[-2]}/{parts[-1]}"
    elif ecosystem == "go" and len(parts) >= 2:
        name = "/".join(parts)
    else:
        name = parts[-1]
    return ecosystem, name, version


def _sbom_record(
    name: str, version: str | None, ecosystem: str, source_file: str
) -> dict[str, Any]:
    return _record(name, version or "", ecosystem, source_file)


def parse_sbom_json_text(
    text: str, source_file: str = "sbom.json"
) -> list[dict[str, Any]]:
    """Parse CycloneDX or SPDX JSON SBOMs into dependency records."""
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        logger.warning("Failed to parse SBOM JSON %s: %s", source_file, exc)
        return []
    if not isinstance(data, dict):
        return []

    records: list[dict[str, Any]] = []
    if data.get("bomFormat") == "CycloneDX" or isinstance(data.get("components"), list):
        for comp in data.get("components") or []:
            if not isinstance(comp, dict):
                continue
            parsed = _parse_purl(str(comp.get("purl") or ""))
            if parsed:
                ecosystem, name, ver = parsed
                records.append(
                    _sbom_record(name, ver or comp.get("version"), ecosystem, source_file)
                )
            elif comp.get("name"):
                records.append(
                    _sbom_record(
                        str(comp["name"]), comp.get("version"), "sbom", source_file
                    )
                )
        return records

    if data.get("spdxVersion") or isinstance(data.get("packages"), list):
        for pkg in data.get("packages") or []:
            if not isinstance(pkg, dict):
                continue
            purl = ""
            for ref in pkg.get("externalRefs") or []:
                if isinstance(ref, dict) and ref.get("referenceType") == "purl":
                    purl = str(ref.get("referenceLocator") or "")
                    break
            parsed = _parse_purl(purl)
            if parsed:
                ecosystem, name, ver = parsed
                records.append(
                    _sbom_record(
                        name, ver or pkg.get("versionInfo"), ecosystem, source_file
                    )
                )
            elif pkg.get("name"):
                records.append(
                    _sbom_record(
                        str(pkg["name"]), pkg.get("versionInfo"), "sbom", source_file
                    )
                )
    return records


# ---------------------------------------------------------------------------
# File / repo entry points
# ---------------------------------------------------------------------------

_PARSERS = {
    "pyproject.toml": parse_pyproject_text,
    "package.json": parse_package_json_text,
    "pubspec.yaml": parse_pubspec_text,
    "uv.lock": parse_uv_lock_text,
    "package-lock.json": parse_package_lock_text,
    "bom.json": parse_sbom_json_text,
    "sbom.json": parse_sbom_json_text,
}


def _parser_for_filename(filename: str):
    parser = _PARSERS.get(filename)
    if parser is not None:
        return parser
    lower = filename.lower()
    if lower.endswith((".cdx.json", ".spdx.json")):
        return parse_sbom_json_text
    return None


def extract_dependencies_from_file(path: str | Path) -> list[dict[str, Any]]:
    """Extract dependencies from one manifest file (empty if unsupported)."""
    file_path = Path(path)
    parser = _parser_for_filename(file_path.name)
    if parser is None:
        return []
    try:
        text = file_path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        logger.warning("Unreadable manifest %s: %s", file_path, exc)
        return []
    return parser(text, source_file=file_path.name)


def is_dependency_manifest_path(rel_path: str) -> bool:
    """Return True if ``rel_path`` is a supported manifest outside skipped dirs."""
    clean_parts = [p for p in Path(rel_path).parts if p and p != "."]
    if not clean_parts or any(p == ".." or p.startswith("/") for p in clean_parts):
        return False
    if any(part in _SKIPPED_DIRS for part in clean_parts[:-1]):
        return False
    return _parser_for_filename(clean_parts[-1]) is not None


def _is_allowed_manifest(path: Path, root_path: Path) -> bool:
    if _parser_for_filename(path.name) is None or path.is_symlink() or not path.is_file():
        return False
    try:
        if os.path.commonpath([str(root_path), os.path.realpath(path)]) != str(
            root_path
        ):
            return False
    except ValueError:
        return False
    relative = path.relative_to(root_path)
    return not any(part in _SKIPPED_DIRS for part in relative.parts[:-1])


def extract_dependencies_from_repo(root: str | Path) -> list[dict[str, Any]]:
    """Extract dependencies from every manifest under ``root``.

    Walks the tree skipping vendored/build directories; each record's
    ``source_file`` is the repo-relative manifest path.
    """
    root_path = Path(os.path.realpath(root))
    records: list[dict[str, Any]] = []
    if not root_path.is_dir():
        return records
    for path in sorted(root_path.rglob("*")):
        if not _is_allowed_manifest(path, root_path):
            continue
        relative = path.relative_to(root_path)
        for record in extract_dependencies_from_file(path):
            record = dict(record)
            record["source_file"] = relative.as_posix()
            records.append(record)
    return records


__all__ = [
    "MANIFEST_NAMES",
    "extract_dependencies_from_file",
    "extract_dependencies_from_repo",
    "is_dependency_manifest_path",
    "normalize_package_name",
    "parse_package_json_text",
    "parse_pubspec_text",
    "parse_pyproject_text",
    "parse_sbom_json_text",
    "parse_version_spec",
]
