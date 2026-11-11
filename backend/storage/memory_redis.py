"""In-memory async Redis-compatible adapter for single-container (REDIS_URL=memory://) deployments."""

from __future__ import annotations

from typing import Any, Callable
import builtins


def _to_bytes(val: Any) -> bytes:
    if isinstance(val, bytes):
        return val
    return str(val).encode("utf-8")


class InMemoryRedisPool:
    """Lightweight async in-memory replacement for ARQ/redis-py pool when REDIS_URL=memory://."""

    def __init__(self) -> None:
        self._kv: dict[str, bytes] = {}
        self._hashes: dict[str, dict[bytes, bytes]] = {}
        self._sets: dict[str, set[bytes]] = {}

    async def get(self, key: str) -> bytes | None:
        return self._kv.get(key)

    async def set(self, key: str, value: Any, *args: Any, **kwargs: Any) -> bool:
        self._kv[key] = _to_bytes(value)
        return True

    async def setex(self, key: str, ttl: int, value: Any) -> bool:
        self._kv[key] = _to_bytes(value)
        return True

    async def expire(self, key: str, ttl: int) -> bool:
        return True

    async def delete(self, *keys: str) -> int:
        removed = 0
        for k in keys:
            removed += int(k in self._kv or k in self._hashes or k in self._sets)
            self._kv.pop(k, None)
            self._hashes.pop(k, None)
            self._sets.pop(k, None)
        return removed

    async def hset(
        self,
        name: str,
        key: str | None = None,
        value: Any = None,
        mapping: dict[Any, Any] | None = None,
    ) -> int:
        bucket = self._hashes.setdefault(name, {})
        count = 0
        if key is not None and value is not None:
            bucket[_to_bytes(key)] = _to_bytes(value)
            count += 1
        if mapping:
            for mk, mv in mapping.items():
                bucket[_to_bytes(mk)] = _to_bytes(mv)
                count += 1
        return count

    async def hget(self, name: str, key: str) -> bytes | None:
        return self._hashes.get(name, {}).get(_to_bytes(key))

    async def hgetall(self, name: str) -> dict[bytes, bytes]:
        return dict(self._hashes.get(name, {}))

    async def hdel(self, name: str, *keys: str) -> int:
        bucket = self._hashes.get(name, {})
        removed = 0
        for k in keys:
            if _to_bytes(k) in bucket:
                del bucket[_to_bytes(k)]
                removed += 1
        return removed

    async def hexists(self, name: str, key: str) -> bool:
        return _to_bytes(key) in self._hashes.get(name, {})

    async def sadd(self, name: str, *values: Any) -> int:
        s = self._sets.setdefault(name, set())
        before = len(s)
        for v in values:
            s.add(_to_bytes(v))
        return len(s) - before

    async def srem(self, name: str, *values: Any) -> int:
        s = self._sets.get(name, set())
        before = len(s)
        for v in values:
            s.discard(_to_bytes(v))
        return before - len(s)

    async def smembers(self, name: str) -> builtins.set[bytes]:
        return set(self._sets.get(name, set()))

    async def sismember(self, name: str, value: Any) -> bool:
        return _to_bytes(value) in self._sets.get(name, set())

    async def publish(self, channel: str, message: Any) -> int:
        return 0

    def pubsub(self):
        return _InMemoryPubSub()

    async def close(self) -> None:
        return None


class _InMemoryPubSub:
    async def subscribe(self, *channels: str) -> None:
        return None

    async def unsubscribe(self, *channels: str) -> None:
        return None

    async def listen(self):
        if False:
            yield {}
