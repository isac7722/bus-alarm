from __future__ import annotations

from collections.abc import AsyncIterator, Mapping
from datetime import UTC, datetime, timedelta
from typing import Any

import httpx
import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from app.cache.rate_limit import RateLimitResult
from app.clients.seoul_bus_client import SeoulArrivalResult
from app.core.database import get_database_session
from app.core.exceptions import AppError, ErrorCode
from app.main import create_app
from app.schemas.arrival import ArrivalPrediction, RouteArrival, VehicleStatus


class FakeCache:
    """Cache double sufficient for health and empty arrival tests."""

    async def ping(self) -> None:
        return None

    async def get_json(self, _key: str) -> dict[str, Any] | None:
        return None

    async def set_json(self, _key: str, _value: dict[str, Any]) -> None:
        return None


class ArrivalClient:
    """Client double that returns one normalized route prediction."""

    async def get_arrivals(
        self,
        _station_id: str,
        _route_names: Mapping[str, str] | None = None,
    ) -> SeoulArrivalResult:
        updated_at = datetime(2026, 8, 12, 0, 27, tzinfo=UTC)
        return SeoulArrivalResult(
            updated_at=updated_at,
            fetched_at=updated_at,
            arrivals=[
                RouteArrival(
                    route_id="100100341",
                    route_name="341",
                    predictions=[
                        ArrivalPrediction(
                            order=1,
                            arrival_at=updated_at + timedelta(seconds=180),
                            remaining_seconds=180,
                            remaining_stops=2,
                            vehicle_status=VehicleStatus.RUNNING,
                        )
                    ],
                )
            ],
        )


class AllowingLimiter:
    """Rate limiter double."""

    async def check(self, _identity: str) -> RateLimitResult:
        return RateLimitResult(allowed=True, remaining=59, retry_after=60)


class DenyingLimiter:
    """Exhausted rate limiter double."""

    async def check(self, _identity: str) -> RateLimitResult:
        return RateLimitResult(allowed=False, remaining=0, retry_after=42)


class FailingLimiter:
    """Unavailable Redis rate limiter double."""

    async def check(self, _identity: str) -> RateLimitResult:
        raise AppError(ErrorCode.CACHE_ERROR, "캐시 서버를 일시적으로 사용할 수 없습니다.", 503)


@pytest.fixture
async def api_client(seeded_session: AsyncSession) -> AsyncIterator[httpx.AsyncClient]:
    application = create_app()

    async def override_session() -> AsyncIterator[AsyncSession]:
        yield seeded_session

    application.dependency_overrides[get_database_session] = override_session
    application.state.cache = FakeCache()
    application.state.seoul_bus_client = ArrivalClient()
    application.state.rate_limiter = AllowingLimiter()
    transport = httpx.ASGITransport(app=application)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        yield client


@pytest.mark.asyncio
async def test_health(api_client: httpx.AsyncClient) -> None:
    response = await api_client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


@pytest.mark.asyncio
async def test_station_search_and_detail(api_client: httpx.AsyncClient) -> None:
    search = await api_client.get("/api/v1/stations/search", params={"q": "강남"})
    detail = await api_client.get("/api/v1/stations/22001")

    assert search.status_code == 200
    assert search.json()["stations"][0]["ars_id"] == "22-001"
    assert detail.status_code == 200
    assert len(detail.json()["routes"]) == 2


@pytest.mark.asyncio
async def test_blank_search_uses_unified_error(api_client: httpx.AsyncClient) -> None:
    response = await api_client.get("/api/v1/stations/search", params={"q": " "})
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "INVALID_REQUEST"


@pytest.mark.asyncio
async def test_invalid_station_id_uses_unified_error(api_client: httpx.AsyncClient) -> None:
    response = await api_client.get("/api/v1/stations/not-an-id")
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "INVALID_REQUEST"


@pytest.mark.asyncio
async def test_arrivals_endpoint_filters_and_serializes_predictions(api_client: httpx.AsyncClient) -> None:
    response = await api_client.get(
        "/api/v1/stations/22001/arrivals",
        params={"route_ids": "100100341"},
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["station"] == {"station_id": "22001", "name": "강남역"}
    assert payload["arrivals"][0]["route_name"] == "341"
    assert payload["arrivals"][0]["predictions"][0]["remaining_seconds"] == 180


@pytest.mark.asyncio
async def test_rate_limit_returns_retry_after(seeded_session: AsyncSession) -> None:
    application = create_app()

    async def override_session() -> AsyncIterator[AsyncSession]:
        yield seeded_session

    application.dependency_overrides[get_database_session] = override_session
    application.state.rate_limiter = DenyingLimiter()
    application.state.cache = FakeCache()
    transport = httpx.ASGITransport(app=application)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get("/api/v1/stations/search", params={"q": "강남"})

    assert response.status_code == 429
    assert response.headers["retry-after"] == "42"
    assert response.json()["error"]["code"] == "RATE_LIMIT_EXCEEDED"


@pytest.mark.asyncio
async def test_rate_limit_cache_failure_uses_unified_error(seeded_session: AsyncSession) -> None:
    application = create_app()

    async def override_session() -> AsyncIterator[AsyncSession]:
        yield seeded_session

    application.dependency_overrides[get_database_session] = override_session
    application.state.rate_limiter = FailingLimiter()
    application.state.cache = FakeCache()
    transport = httpx.ASGITransport(app=application)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get("/api/v1/stations/search", params={"q": "강남"})

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "CACHE_ERROR"
