from __future__ import annotations

from collections.abc import Mapping
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from app.clients.seoul_bus_client import SeoulArrivalResult
from app.core.exceptions import AppError, ErrorCode
from app.repositories.station_repository import StationRepository
from app.schemas.arrival import ArrivalPrediction, RouteArrival, VehicleStatus
from app.services.arrival_service import ArrivalService


class FakeCache:
    """In-memory cache test double."""

    def __init__(self) -> None:
        self.values: dict[str, dict[str, Any]] = {}

    async def get_json(self, key: str) -> dict[str, Any] | None:
        return self.values.get(key)

    async def set_json(self, key: str, value: dict[str, Any]) -> None:
        self.values[key] = value


class FakeClient:
    """Deterministic upstream client test double."""

    calls = 0

    async def get_arrivals(
        self,
        _station_id: str,
        _route_names: Mapping[str, str] | None = None,
    ) -> SeoulArrivalResult:
        self.calls += 1
        now = datetime(2026, 8, 12, 0, 27, tzinfo=UTC)
        return SeoulArrivalResult(
            updated_at=now,
            fetched_at=now,
            arrivals=[
                RouteArrival(
                    route_id="100100341",
                    route_name="341",
                    predictions=[
                        ArrivalPrediction(
                            order=1,
                            arrival_at=now + timedelta(seconds=180),
                            remaining_seconds=180,
                            remaining_stops=2,
                            vehicle_status=VehicleStatus.RUNNING,
                        )
                    ],
                )
            ],
        )


@pytest.mark.asyncio
async def test_arrivals_filters_routes_and_uses_cache(seeded_session: AsyncSession) -> None:
    cache = FakeCache()
    client = FakeClient()
    service = ArrivalService(StationRepository(seeded_session), client, cache)  # type: ignore[arg-type]

    first = await service.get_arrivals("22001", ["100100341"])
    second = await service.get_arrivals("22001", ["100100341"])

    assert [arrival.route_name for arrival in first.arrivals] == ["341"]
    assert second == first
    assert client.calls == 1


@pytest.mark.asyncio
async def test_arrivals_rejects_unknown_route(seeded_session: AsyncSession) -> None:
    service = ArrivalService(StationRepository(seeded_session), FakeClient(), FakeCache())  # type: ignore[arg-type]

    with pytest.raises(AppError) as captured:
        await service.get_arrivals("22001", ["missing"])

    assert captured.value.code == ErrorCode.ROUTE_NOT_FOUND


@pytest.mark.asyncio
async def test_arrivals_limits_route_count(seeded_session: AsyncSession) -> None:
    service = ArrivalService(StationRepository(seeded_session), FakeClient(), FakeCache())  # type: ignore[arg-type]

    with pytest.raises(AppError) as captured:
        await service.get_arrivals("22001", ["1", "2", "3", "4", "5"])

    assert captured.value.status_code == 400


@pytest.mark.asyncio
async def test_arrivals_preserves_requested_route_without_upstream_prediction(seeded_session: AsyncSession) -> None:
    service = ArrivalService(StationRepository(seeded_session), FakeClient(), FakeCache())  # type: ignore[arg-type]

    response = await service.get_arrivals("22001", ["100100360"])

    assert len(response.arrivals) == 1
    assert response.arrivals[0].route_id == "100100360"
    assert response.arrivals[0].route_name == "360"
    assert response.arrivals[0].predictions == []
