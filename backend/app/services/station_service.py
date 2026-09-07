from __future__ import annotations

from app.core.exceptions import AppError, ErrorCode
from app.models.catalog import Station
from app.repositories.station_repository import StationRepository
from app.schemas.station import (
    RouteSummary,
    StationDetailResponse,
    StationSearchResponse,
    StationSummary,
    format_ars_id,
)


class StationService:
    """Station search and detail behavior."""

    def __init__(self, repository: StationRepository) -> None:
        """Initialize the service."""
        self.repository = repository

    async def search(self, keyword: str) -> StationSearchResponse:
        """Search stations after validating a meaningful query."""
        normalized = keyword.strip()
        if not normalized:
            raise AppError(ErrorCode.INVALID_REQUEST, "검색어를 입력해 주세요.", 400)
        stations = await self.repository.search(normalized, limit=20)
        return StationSearchResponse(stations=[self._summary(station) for station in stations])

    async def detail(self, station_id: str) -> StationDetailResponse:
        """Return one station and its available routes."""
        station = await self.require_station(station_id)
        routes = await self.repository.get_routes(station_id)
        return StationDetailResponse(
            station=self._summary(station),
            routes=[RouteSummary(route_id=route.route_id, route_name=route.name) for route in routes],
        )

    async def require_station(self, station_id: str) -> Station:
        """Return a station or raise the public not-found error."""
        station = await self.repository.get(station_id)
        if station is None:
            raise AppError(ErrorCode.STATION_NOT_FOUND, "정류소를 찾을 수 없습니다.", 404)
        return station

    @staticmethod
    def _summary(station: Station) -> StationSummary:
        return StationSummary(
            station_id=station.station_id,
            ars_id=format_ars_id(station.station_id),
            name=station.name,
            direction=None,
            latitude=station.latitude,
            longitude=station.longitude,
        )
