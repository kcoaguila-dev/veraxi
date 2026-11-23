-- Migration: 008_code_threads.sql
-- Creates the Code Mode thread-metadata table (Veraxi Code Mode Phase 1):
-- one row per chat thread recording which workspace mode the thread
-- belongs to ('chat' or 'code'), which indexed repo / branch it is
-- scoped to, and the user's selected sources for that thread.
--
-- This is a NEW table on purpose: there is no ``chat_threads`` table
-- to alter — server-side thread membership lives in Redis
-- (``tenant:{id}:threads``) and message history in the LangGraph
-- Postgres checkpointer. ``thread_metadata`` is the durable,
-- queryable mirror of the per-thread code metadata the chat routes
-- keep in the Redis ``thread_code_meta`` hash.
-- Apply via: Supabase Dashboard → SQL Editor, or psql.

CREATE TABLE IF NOT EXISTS thread_metadata (
    tenant_id       TEXT        NOT NULL,
    thread_id       TEXT        NOT NULL,
    workspace_mode  TEXT        NOT NULL DEFAULT 'chat',  -- 'chat' | 'code'
    repo_key        TEXT,
    branch          TEXT,
    selected_sources JSONB      NOT NULL DEFAULT '{}'::jsonb,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, thread_id)
);

-- Index for listing a tenant's threads by mode / repo, most recent first
-- (the GET /api/chat/threads workspace_mode & repo_key filters).
CREATE INDEX IF NOT EXISTS thread_metadata_tenant_mode_repo_idx
    ON thread_metadata (tenant_id, workspace_mode, repo_key, updated_at DESC);

-- Row-Level Security: a logged-in user can only see/modify rows for
-- their own tenant. The service-role key (used by the backend)
-- bypasses RLS entirely.
ALTER TABLE thread_metadata ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_own_thread_metadata" ON thread_metadata
    FOR ALL
    USING (tenant_id = auth.uid()::TEXT)
    WITH CHECK (tenant_id = auth.uid()::TEXT);
