-- Migration: 001_api_keys.sql
-- Creates the personal API key table for persistent MCP access.
--
-- Raw keys are NEVER stored here. Only the SHA-256 hash is persisted.
-- Apply via: Supabase Dashboard → SQL Editor, or psql.

CREATE TABLE IF NOT EXISTS api_keys (
    id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    TEXT        NOT NULL,
    name         TEXT        NOT NULL,                          -- user-chosen label, e.g. "Cursor on MacBook"
    key_hash     TEXT        NOT NULL UNIQUE,                   -- sha256(raw_key)
    key_prefix   TEXT        NOT NULL,                          -- first 10 chars for display, e.g. "vx-a1b2c3d4"
    is_active    BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at TIMESTAMPTZ,                                   -- updated on every successful auth
    expires_at   TIMESTAMPTZ                                    -- NULL = never expires
);

-- Fast index for the hot path: every SSE connection does a hash lookup
CREATE INDEX IF NOT EXISTS api_keys_hash_active_idx
    ON api_keys (key_hash)
    WHERE is_active = TRUE;

-- Index for listing a tenant's own keys efficiently
CREATE INDEX IF NOT EXISTS api_keys_tenant_idx
    ON api_keys (tenant_id);

-- Row-Level Security: a logged-in user can only see/modify their own rows.
-- The service-role key (used by the backend) bypasses RLS entirely.
ALTER TABLE api_keys ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_own_keys" ON api_keys
    FOR ALL
    USING (tenant_id = auth.uid()::TEXT)
    WITH CHECK (tenant_id = auth.uid()::TEXT);
