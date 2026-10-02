-- Migration: 003_user_sync.sql
-- Creates the user_sync_data table for securely storing encrypted API keys.
--
-- Apply via: Supabase Dashboard → SQL Editor, or psql.

CREATE TABLE IF NOT EXISTS user_sync_data (
    tenant_id      TEXT        PRIMARY KEY,
    encrypted_blob TEXT        NOT NULL,
    salt           TEXT        NOT NULL,
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Row-Level Security
ALTER TABLE user_sync_data ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_own_sync_data" ON user_sync_data
    FOR ALL
    USING (tenant_id = auth.uid()::TEXT)
    WITH CHECK (tenant_id = auth.uid()::TEXT);
