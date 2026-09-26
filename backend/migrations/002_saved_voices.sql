-- Migration: 002_saved_voices.sql
-- Creates the saved_voices table to allow users to persist their favorite Fish Audio voices.
--
-- Apply via: Supabase Dashboard → SQL Editor, or psql.

CREATE TABLE IF NOT EXISTS saved_voices (
    id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    name         TEXT        NOT NULL,                          -- user-chosen label, e.g. "My favorite AI voice"
    reference_id TEXT        NOT NULL,                          -- the Fish Audio reference ID
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Fast index for querying a user's voices
CREATE INDEX IF NOT EXISTS saved_voices_user_idx
    ON saved_voices (user_id);

-- Row-Level Security: a logged-in user can only see/modify their own rows.
ALTER TABLE saved_voices ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_own_voices_select" ON saved_voices FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "users_own_voices_insert" ON saved_voices FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY "users_own_voices_update" ON saved_voices FOR UPDATE USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
CREATE POLICY "users_own_voices_delete" ON saved_voices FOR DELETE USING (user_id = auth.uid());
