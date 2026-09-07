from __future__ import annotations

from types import TracebackType

import pytest
from redis.exceptions import RedisError

from app.cache.rate_limit import RedisRateLimiter
from app.core.exceptions import AppError, ErrorCode


class FakePipeline:
    """Redis pipeline double with fixed counter results."""

    def __init__(self, count: int, ttl: int, *, should_fail: bool = False) -> None:
        self.count = count
        self.ttl_value = ttl
        self.should_fail = should_fail
        self.keys: list[str] = []

    async def __aenter__(self) -> FakePipeline:
        return self

    async def __aexit__(
        self,
        _exception_type: type[BaseException] | None,
        _exception: BaseException | None,
        _traceback: TracebackType | None,
    ) -> None:
        return None

    def incr(self, key: str) -> FakePipeline:
        self.keys.append(key)
        return self

    def ttl(self, key: str) -> FakePipeline:
        self.keys.append(key)
        return self

    async def execute(self) -> tuple[int, int]:
        if self.should_fail:
            raise RedisError("unavailable")
        return self.count, self.ttl_value


class FakeRedis:
    """Minimal Redis double for rate-limit behavior."""

    def __init__(self, count: int, ttl: int, *, should_fail: bool = False) -> None:
        self.pipeline_double = FakePipeline(count, ttl, should_fail=should_fail)
        self.expirations: list[tuple[str, int]] = []

    def pipeline(self, *, transaction: bool) -> FakePipeline:
        assert transaction is True
        return self.pipeline_double

    async def expire(self, key: str, seconds: int) -> bool:
        self.expirations.append((key, seconds))
        return True


@pytest.mark.asyncio
async def test_first_request_starts_window() -> None:
    redis = FakeRedis(count=1, ttl=-1)
    limiter = RedisRateLimiter(redis, requests=2, window_seconds=60)  # type: ignore[arg-type]

    result = await limiter.check("127.0.0.1")

    assert result.allowed is True
    assert result.remaining == 1
    assert result.retry_after == 60
    assert redis.expirations == [("rate:127.0.0.1", 60)]


@pytest.mark.asyncio
async def test_request_over_limit_is_denied() -> None:
    redis = FakeRedis(count=3, ttl=24)
    limiter = RedisRateLimiter(redis, requests=2, window_seconds=60)  # type: ignore[arg-type]

    result = await limiter.check("127.0.0.1")

    assert result.allowed is False
    assert result.remaining == 0
    assert result.retry_after == 24
    assert redis.expirations == []


@pytest.mark.asyncio
async def test_rate_limiter_maps_redis_failure() -> None:
    redis = FakeRedis(count=0, ttl=0, should_fail=True)
    limiter = RedisRateLimiter(redis, requests=2, window_seconds=60)  # type: ignore[arg-type]

    with pytest.raises(AppError) as captured:
        await limiter.check("127.0.0.1")

    assert captured.value.code == ErrorCode.CACHE_ERROR
    assert captured.value.status_code == 503
