-- Migration: 008_github_app.sql
-- Stores verified GitHub App installations bound to Veraxi tenants and
-- tracks indexed repository sync state.
--
-- User-to-server OAuth tokens are stored ONLY as Fernet ciphertext via
-- backend/security/token_vault.py in encrypted_user_tokens and are never
-- returned by any API endpoint. Installation access tokens (1h TTL) are
-- minted on demand and cached transiently in Redis, never persisted here.

CREATE TABLE IF NOT EXISTS github_app_installations (
    id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id             TEXT        NOT NULL,
    installation_id       BIGINT      NOT NULL,
    github_account_id     BIGINT      NOT NULL,
    github_account_login  TEXT        NOT NULL,
    github_account_type   TEXT        NOT NULL, -- 'User' | 'Organization'
    repository_selection  TEXT        NOT NULL DEFAULT 'selected', -- 'selected' | 'all'
    permissions           JSONB       NOT NULL DEFAULT '{}'::jsonb,
    status                TEXT        NOT NULL DEFAULT 'active',   -- 'active' | 'suspended' | 'deleted'
    encrypted_user_tokens TEXT,
    user_token_expires_at TIMESTAMPTZ,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, installation_id)
);

CREATE INDEX IF NOT EXISTS gh_app_installations_installation_idx
    ON github_app_installations (installation_id);

CREATE INDEX IF NOT EXISTS gh_app_installations_tenant_idx
    ON github_app_installations (tenant_id);

CREATE TABLE IF NOT EXISTS github_app_repos (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           TEXT        NOT NULL,
    installation_id     BIGINT      NOT NULL,
    github_repo_id      BIGINT      NOT NULL,
    repo_full_name      TEXT        NOT NULL, -- "owner/repo" (also Neo4j repo_key)
    default_branch      TEXT        NOT NULL DEFAULT 'main',
    is_private          BOOLEAN     NOT NULL DEFAULT TRUE,
    auto_sync_on_push   BOOLEAN     NOT NULL DEFAULT TRUE,
    index_status        TEXT        NOT NULL DEFAULT 'connected', -- 'connected' | 'indexing' | 'indexed' | 'error'
    last_indexed_sha      TEXT,
    last_indexed_at       TIMESTAMPTZ,
    last_error            TEXT,
    dependencies_snapshot JSONB       NOT NULL DEFAULT '[]'::jsonb,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, repo_full_name)
);

CREATE INDEX IF NOT EXISTS gh_app_repos_lookup_idx
    ON github_app_repos (installation_id, repo_full_name);

ALTER TABLE github_app_installations ENABLE ROW LEVEL SECURITY;
ALTER TABLE github_app_repos ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_own_gh_app_installations" ON github_app_installations
    FOR ALL
    USING (tenant_id = auth.uid()::TEXT)
    WITH CHECK (tenant_id = auth.uid()::TEXT);

CREATE POLICY "users_own_gh_app_repos" ON github_app_repos
    FOR ALL
    USING (tenant_id = auth.uid()::TEXT)
    WITH CHECK (tenant_id = auth.uid()::TEXT);
