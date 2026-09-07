from __future__ import annotations

import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.exceptions import AppError, ErrorCode
from app.repositories.station_repository import StationRepository
from app.services.station_service import StationService


@pytest.mark.asyncio
async def test_search_returns_formatted_ars_id(seeded_session: AsyncSession) -> None:
    service = StationService(StationRepository(seeded_session))

    response = await service.search("강남")

    assert len(response.stations) == 1
    assert response.stations[0].station_id == "22001"
    assert response.stations[0].ars_id == "22-001"
    assert response.stations[0].direction is None


@pytest.mark.asyncio
async def test_search_rejects_blank_query(seeded_session: AsyncSession) -> None:
    service = StationService(StationRepository(seeded_session))

    with pytest.raises(AppError) as captured:
        await service.search("   ")

    assert captured.value.code == ErrorCode.INVALID_REQUEST


@pytest.mark.asyncio
async def test_detail_returns_routes(seeded_session: AsyncSession) -> None:
    service = StationService(StationRepository(seeded_session))

    response = await service.detail("22001")

    assert [route.route_name for route in response.routes] == ["341", "360"]
