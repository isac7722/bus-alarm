from __future__ import annotations

from dataclasses import dataclass

from redis.asyncio import Redis
from redis.exceptions import RedisError

from app.core.exceptions import AppError, ErrorCode


@dataclass(frozen=True, slots=True)
class RateLimitResult:
    """Current state of a fixed-window rate limit."""

    allowed: bool
    remaining: int
    retry_after: int


class RedisRateLimiter:
    """IP-based fixed-window limiter stored in required Redis."""

    def __init__(self, redis: Redis, requests: int, window_seconds: int) -> None:
        """Initialize rate limit parameters."""
        self.redis = redis
        self.requests = requests
        self.window_seconds = window_seconds

    async def check(self, identity: str) -> RateLimitResult:
        """Increment an identity's current window and return its allowance."""
        key = f"rate:{identity}"
        try:
            async with self.redis.pipeline(transaction=True) as pipeline:
                pipeline.incr(key)
                pipeline.ttl(key)
                count, ttl = await pipeline.execute()
            count = int(count)
            ttl = int(ttl)
            if count == 1 or ttl < 0:
                await self.redis.expire(key, self.window_seconds)
                ttl = self.window_seconds
        except RedisError as error:
            raise AppError(ErrorCode.CACHE_ERROR, "캐시 서버를 일시적으로 사용할 수 없습니다.", 503) from error
        return RateLimitResult(
            allowed=count <= self.requests,
            remaining=max(self.requests - count, 0),
            retry_after=max(ttl, 1),
        )
