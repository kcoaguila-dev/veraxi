"""Tests for the user-memory store (migration 007 / Phase 5)."""

import pytest

from backend.services import memory_store as store
from test_sandbox_manager import FakeSupabase


class TestMemoryStore:
    def test_create_and_public_view(self):
        fake = FakeSupabase()
        row = store.create_memory(fake, "tenant-1", "user-1", "Prefers concise answers")
        assert row["tenant_id"] == "tenant-1"
        assert row["user_id"] == "user-1"
        assert row["source"] == "manual"
        view = store.public_view(row)
        assert view["content"] == "Prefers concise answers"
        assert view["is_valid"] is True
        assert view["valid_to"] is None

    def test_create_rejects_empty_content_and_bad_source(self):
        fake = FakeSupabase()
        with pytest.raises(ValueError):
            store.create_memory(fake, "t", "u", "   ")
        with pytest.raises(ValueError):
            store.create_memory(fake, "t", "u", "x", source="telepathy")

    def test_list_is_tenant_and_user_scoped(self):
        fake = FakeSupabase()
        store.create_memory(fake, "t1", "u1", "mine")
        store.create_memory(fake, "t1", "u2", "other user")
        store.create_memory(fake, "t2", "u1", "other tenant")
        rows = store.list_memories(fake, "t1", "u1")
        assert [r["content"] for r in rows] == ["mine"]

    def test_get_update_delete_scoped(self):
        fake = FakeSupabase()
        row = store.create_memory(fake, "t1", "u1", "original", source="chat")
        memory_id = row["id"]
        assert store.get_memory(fake, "t1", "u2", memory_id) is None
        assert store.get_memory(fake, "t2", "u1", memory_id) is None

        updated = store.update_memory(
            fake, "t1", "u1", memory_id, {"content": "edited"}
        )
        assert updated["content"] == "edited"
        assert updated["source"] == "chat"

        assert store.delete_memory(fake, "t1", "u2", memory_id) is False
        assert store.delete_memory(fake, "t1", "u1", memory_id) is True
        assert store.get_memory(fake, "t1", "u1", memory_id) is None

    def test_expire_soft_expires_and_filters(self):
        fake = FakeSupabase()
        row = store.create_memory(fake, "t1", "u1", "temporary fact")
        expired = store.expire_memory(fake, "t1", "u1", row["id"])
        assert expired["valid_to"] is not None
        assert store.public_view(expired)["is_valid"] is False
        # Row is kept (soft-expire), but filtered when expired excluded.
        assert len(store.list_memories(fake, "t1", "u1")) == 1
        assert store.list_memories(fake, "t1", "u1", include_expired=False) == []
        assert store.expire_memory(fake, "t1", "u2", row["id"]) is None
