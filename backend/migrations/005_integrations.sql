-- Migration: 005_integrations.sql
-- Creates the per-tenant external integrations table (MCP servers,
-- OAuth connectors, and imported OpenAPI actions).
--
-- Secrets are NEVER stored in plaintext here. ``encrypted_secrets`` holds
-- a Fernet ciphertext (see backend/security/token_vault.py) of a JSON
-- object such as {"access_token": ..., "refresh_token": ...,
-- "headers": {...}, "api_key": ...}. It must never be returned by the
-- API; list/get responses expose only a boolean ``has_auth`` indicator.
-- Apply via: Supabase Dashboard → SQL Editor, or psql.

CREATE TABLE IF NOT EXISTS tenant_integrations (
    id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        TEXT        NOT NULL,
    kind             TEXT        NOT NULL,  -- 'mcp' | 'oauth' | 'openapi'
    provider         TEXT        NOT NULL,  -- e.g. 'custom_mcp', 'github', 'google_drive', 'notion', 'custom_openapi'
    slug             TEXT        NOT NULL,  -- sanitized [a-z0-9_-]+, unique per tenant; used in tool names
    display_name     TEXT        NOT NULL,
    config           JSONB       NOT NULL DEFAULT '{}'::jsonb,  -- non-secret metadata (server URL, transport, spec subset, selected repos, ...)
    encrypted_secrets TEXT,                                     -- Fernet ciphertext of the secrets JSON; never returned by the API
    token_expires_at TIMESTAMPTZ,
    scopes           TEXT[]      NOT NULL DEFAULT '{}',
    is_enabled       BOOLEAN     NOT NULL DEFAULT TRUE,
    status           TEXT        NOT NULL DEFAULT 'connected',  -- 'connected' | 'error' | 'expired'
    last_synced_at   TIMESTAMPTZ,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, slug)
);

-- Index for listing a tenant's own integrations efficiently
CREATE INDEX IF NOT EXISTS tenant_integrations_tenant_idx
    ON tenant_integrations (tenant_id);

-- Row-Level Security: a logged-in user can only see/modify their own rows.
-- The service-role key (used by the backend) bypasses RLS entirely.
ALTER TABLE tenant_integrations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_own_integrations" ON tenant_integrations
    FOR ALL
    USING (tenant_id = auth.uid()::TEXT)
    WITH CHECK (tenant_id = auth.uid()::TEXT);
