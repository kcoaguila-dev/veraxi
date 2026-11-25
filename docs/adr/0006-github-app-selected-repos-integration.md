# 6. GitHub App Selected-Repos Read-Only Integration

Date: 2026-11-24

## Status

Accepted

## Context

Veraxi's Connect Repository modal previously staged a **GitHub App** tab behind a "Coming Soon" placeholder while legacy OAuth (`backend/services/oauth_service.py`) requested the broad `repo` OAuth scope for document ingestion.

Enterprise security teams and developers routinely block SaaS code tools that request blanket `repo` OAuth scopes (which grant read/write access to all public and private repositories). Additionally, multi-tenant GitHub App integrations are vulnerable to `installation_id` Insecure Direct Object Reference (IDOR) hijacking if the callback binds a client-supplied `installation_id` without verifying user ownership, and Cloud Run deployments cannot rely on persistent local git clones on container disks.

## Decision

1. **Least-Privilege GitHub App**:
   - Request strictly `Contents: Read-only` and `Metadata: Read-only` permissions, scoped via GitHub's native **"Only select repositories"** picker.
   - Leave legacy OAuth (`oauth_service.py`) untouched for backward compatibility.
2. **IDOR-Proof Installation Binding**:
   - Enable **"Request user authorization (OAuth) during installation"**.
   - On `/api/v1/github-app/callback`, exchange the `code` + PKCE verifier for a user-to-server token, call `GET /user/installations`, and assert the returned `installation_id` belongs to the authenticated GitHub user before binding it to `tenant_id`.
3. **Zero-Retention Ephemeral Indexing & Pinned-SHA Citations**:
   - Download repository tarballs into a temporary directory, parse the AST code graph (`backend/ingestion/code_graph.py`) and dependencies into Neo4j under `repo_key = "owner/repo"` and `kind = "github_app"`, and wipe the temporary directory immediately in `finally:`.
   - Serve cited source lines in `GET /api/v1/code/file` on demand at the pinned `source_commit` using a Redis-cached (50-minute TTL) Installation Access Token.
4. **Fail-Closed Async Webhooks**:
   - `POST /api/v1/github-app/webhook` enforces HMAC-SHA256 signature verification (`X-Hub-Signature-256`) and `X-GitHub-Delivery` deduplication in Redis, enqueuing `push` incremental updates to ARQ and purging Neo4j graph nodes on `installation.deleted` / `installation_repositories.removed`.
5. **Zero New Python Dependencies**:
   - Implement `backend/services/github_app_client.py` using `PyJWT` (`RS256`), `cryptography`, `httpx`, and `redis`, which are already declared in `backend/pyproject.toml`.

## Consequences

- **Positive**: Least-privilege security posture; 1-hour auto-expiring installation tokens; zero source code retained on server disk; Cloud Run compatible; zero new Python dependencies.
- **Negative**: Serving cited code lines for GitHub App repos requires an outbound GitHub API call (mitigated by short-lived Redis caching at the pinned commit SHA).
