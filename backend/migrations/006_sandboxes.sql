-- Migration: 006_sandboxes.sql
-- Creates the per-tenant hybrid agentic coding sandbox tables
-- (cloud serverless sandboxes, remote MCP sandboxes, and the
-- outbound-WebSocket ``veraxi-runner`` on user-owned hardware).
--
-- Secrets are NEVER stored in plaintext here. ``encrypted_secrets`` holds
-- a Fernet ciphertext (see backend/security/token_vault.py) of a JSON
-- object such as {"modal_token_id": ..., "modal_token_secret": ...,
-- "e2b_api_key": ..., "bearer_token": ..., "runner_token": ...}.
-- It must never be returned by the API; responses expose only a boolean
-- ``has_secrets`` indicator.
-- Apply via: Supabase Dashboard → SQL Editor, or psql.

CREATE TABLE IF NOT EXISTS tenant_sandbox_configs (
    id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        TEXT        NOT NULL,
    provider         TEXT        NOT NULL DEFAULT 'disabled',  -- 'disabled' | 'modal' | 'e2b' | 'remote_mcp' | 'local_runner'
    display_name     TEXT        NOT NULL DEFAULT '',
    base_image       TEXT        NOT NULL DEFAULT 'polyglot',  -- 'python' | 'node' | 'flutter' | 'polyglot'
    cpu_cores        INT         NOT NULL DEFAULT 2,
    memory_mb        INT         NOT NULL DEFAULT 4096,
    disk_gb          INT         NOT NULL DEFAULT 10,
    idle_timeout_sec INT         NOT NULL DEFAULT 900,
    max_session_sec  INT         NOT NULL DEFAULT 3600,
    autonomy_mode    TEXT        NOT NULL DEFAULT 'auto_read_test',  -- 'ask_all' | 'auto_read_test' | 'autonomous'
    egress_mode      TEXT        NOT NULL DEFAULT 'allowlist',  -- 'offline' | 'allowlist' | 'unrestricted'
    allowed_domains  TEXT[]      NOT NULL DEFAULT ARRAY['pypi.org','files.pythonhosted.org','registry.npmjs.org','pub.dev','github.com'],
    isolate_git_branch BOOLEAN   NOT NULL DEFAULT TRUE,
    config           JSONB       NOT NULL DEFAULT '{}'::jsonb,  -- non-secret metadata (remote MCP URL, tool names, repo URL, ...)
    encrypted_secrets TEXT,                                     -- Fernet ciphertext of the secrets JSON; never returned by the API
    is_active        BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id)
);

-- Index for listing a tenant's own sandbox config efficiently
CREATE INDEX IF NOT EXISTS tenant_sandbox_configs_tenant_idx
    ON tenant_sandbox_configs (tenant_id);

-- Row-Level Security: a logged-in user can only see/modify their own rows.
-- The service-role key (used by the backend) bypasses RLS entirely.
ALTER TABLE tenant_sandbox_configs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_own_sandbox_configs" ON tenant_sandbox_configs
    FOR ALL
    USING (tenant_id = auth.uid()::TEXT)
    WITH CHECK (tenant_id = auth.uid()::TEXT);

CREATE TABLE IF NOT EXISTS sandbox_sessions (
    id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        TEXT        NOT NULL,
    config_id        UUID        REFERENCES tenant_sandbox_configs(id) ON DELETE SET NULL,
    project_id       TEXT,
    chat_id          TEXT,
    external_sandbox_id TEXT     NOT NULL DEFAULT '',
    status           TEXT        NOT NULL DEFAULT 'starting',  -- 'starting' | 'running' | 'paused' | 'stopped' | 'error'
    git_branch       TEXT        NOT NULL DEFAULT '',
    last_active_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS sandbox_sessions_tenant_idx
    ON sandbox_sessions (tenant_id);

ALTER TABLE sandbox_sessions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_own_sandbox_sessions" ON sandbox_sessions
    FOR ALL
    USING (tenant_id = auth.uid()::TEXT)
    WITH CHECK (tenant_id = auth.uid()::TEXT);
