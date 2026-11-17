-- Migration: 007_user_memories.sql
-- Creates the user-visible memory table (Evidence-First Phase 5):
-- facts/preferences a user can inspect, edit, expire and delete in
-- Settings → Memory. Memories are temporal: ``valid_to`` is NULL while
-- a memory is still valid; setting it soft-expires the memory without
-- deleting the row.
--
-- ``source`` records how the memory arrived: 'chat' (extracted from a
-- conversation), 'manual' (typed by the user in Settings) or 'import'.
-- Apply via: Supabase Dashboard → SQL Editor, or psql.

CREATE TABLE IF NOT EXISTS user_memories (
    id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id  TEXT        NOT NULL,
    user_id    TEXT        NOT NULL,
    content    TEXT        NOT NULL,
    source     TEXT        NOT NULL DEFAULT 'manual',  -- 'chat' | 'manual' | 'import'
    valid_from TIMESTAMPTZ NOT NULL DEFAULT now(),
    valid_to   TIMESTAMPTZ,                            -- NULL = still valid
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Index for listing a tenant/user's memories efficiently
CREATE INDEX IF NOT EXISTS user_memories_tenant_user_idx
    ON user_memories (tenant_id, user_id);

-- Row-Level Security: a logged-in user can only see/modify their own rows.
-- The service-role key (used by the backend) bypasses RLS entirely.
ALTER TABLE user_memories ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_own_memories" ON user_memories
    FOR ALL
    USING (user_id = auth.uid()::TEXT)
    WITH CHECK (user_id = auth.uid()::TEXT);
