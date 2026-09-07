from __future__ import annotations

import json
from typing import Any

from redis.asyncio import Redis
from redis.exceptions import RedisError

from app.core.exceptions import AppError, ErrorCode


class RedisCache:
    """Required Redis cache with explicit, public-safe failures."""

    def __init__(self, redis: Redis, ttl_seconds: int) -> None:
        """Initialize the cache."""
        self.redis = redis
        self.ttl_seconds = ttl_seconds

    async def ping(self) -> None:
        """Verify Redis connectivity."""
        try:
            await self.redis.ping()
        except RedisError as error:
            raise self._cache_error(error) from error

    async def get_json(self, key: str) -> dict[str, Any] | None:
        """Read one JSON object from Redis."""
        try:
            value = await self.redis.get(key)
        except RedisError as error:
            raise self._cache_error(error) from error
        if value is None:
            return None
        try:
            parsed: object = json.loads(value)
        except (json.JSONDecodeError, TypeError) as error:
            raise self._cache_error(error) from error
        if not isinstance(parsed, dict):
            raise self._cache_error(TypeError("Cached JSON value was not an object"))
        return parsed

    async def set_json(self, key: str, value: dict[str, Any]) -> None:
        """Store one JSON object with the configured TTL."""
        try:
            await self.redis.set(key, json.dumps(value, separators=(",", ":")), ex=self.ttl_seconds)
        except RedisError as error:
            raise self._cache_error(error) from error

    async def close(self) -> None:
        """Close the Redis connection pool."""
        await self.redis.aclose()

    @staticmethod
    def _cache_error(error: Exception) -> AppError:
        return AppError(ErrorCode.CACHE_ERROR, "캐시 서버를 일시적으로 사용할 수 없습니다.", 503)
