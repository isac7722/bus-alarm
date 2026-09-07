from __future__ import annotations

import json
from typing import Any

import pytest
from redis.exceptions import RedisError

from app.cache.cache import RedisCache
from app.core.exceptions import AppError, ErrorCode


class FakeRedis:
    """Minimal Redis double for cache behavior."""

    def __init__(self) -> None:
        self.values: dict[str, str] = {}
        self.last_expiry: int | None = None
        self.should_fail = False

    async def ping(self) -> bool:
        if self.should_fail:
            raise RedisError("unavailable")
        return True

    async def get(self, key: str) -> str | None:
        if self.should_fail:
            raise RedisError("unavailable")
        return self.values.get(key)

    async def set(self, key: str, value: str, *, ex: int) -> bool:
        if self.should_fail:
            raise RedisError("unavailable")
        self.values[key] = value
        self.last_expiry = ex
        return True

    async def aclose(self) -> None:
        return None


@pytest.mark.asyncio
async def test_cache_round_trip_uses_configured_ttl() -> None:
    redis = FakeRedis()
    cache = RedisCache(redis, ttl_seconds=30)  # type: ignore[arg-type]
    payload: dict[str, Any] = {"station": {"station_id": "22001"}, "arrivals": []}

    await cache.set_json("station:22001:arrivals", payload)

    assert await cache.get_json("station:22001:arrivals") == payload
    assert redis.last_expiry == 30
    assert json.loads(redis.values["station:22001:arrivals"]) == payload


@pytest.mark.asyncio
async def test_cache_rejects_invalid_json() -> None:
    redis = FakeRedis()
    redis.values["broken"] = "not-json"
    cache = RedisCache(redis, ttl_seconds=30)  # type: ignore[arg-type]

    with pytest.raises(AppError) as captured:
        await cache.get_json("broken")

    assert captured.value.code == ErrorCode.CACHE_ERROR
    assert captured.value.status_code == 503


@pytest.mark.asyncio
async def test_cache_maps_redis_failure_to_public_error() -> None:
    redis = FakeRedis()
    redis.should_fail = True
    cache = RedisCache(redis, ttl_seconds=30)  # type: ignore[arg-type]

    with pytest.raises(AppError) as captured:
        await cache.ping()

    assert captured.value.code == ErrorCode.CACHE_ERROR
    assert "unavailable" not in captured.value.message
