-- Migration: 004_users.sql
-- Creates the users table to track subscriptions.

CREATE TABLE IF NOT EXISTS users (
    id             TEXT        PRIMARY KEY,
    is_subscribed  BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Row-Level Security
ALTER TABLE users ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "users_read_own_profile" ON users;
CREATE POLICY "users_read_own_profile" ON users
    FOR SELECT
    USING (id = auth.uid()::TEXT);
