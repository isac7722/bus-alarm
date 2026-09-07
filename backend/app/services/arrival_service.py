from __future__ import annotations

import structlog

from app.cache.cache import RedisCache
from app.clients.seoul_bus_client import SeoulBusClient
from app.core.exceptions import AppError, ErrorCode
from app.repositories.station_repository import StationRepository
from app.schemas.arrival import ArrivalsResponse, ArrivalStation, RouteArrival

logger = structlog.get_logger(__name__)


class ArrivalService:
    """Orchestrate catalog validation, caching, upstream fetches, and filtering."""

    def __init__(
        self,
        repository: StationRepository,
        client: SeoulBusClient,
        cache: RedisCache,
    ) -> None:
        """Initialize the service dependencies."""
        self.repository = repository
        self.client = client
        self.cache = cache

    async def get_arrivals(self, station_id: str, route_ids: list[str] | None) -> ArrivalsResponse:
        """Return normalized arrivals, optionally limited to validated route IDs."""
        station = await self.repository.get(station_id)
        if station is None:
            raise AppError(ErrorCode.STATION_NOT_FOUND, "정류소를 찾을 수 없습니다.", 404)

        requested = self._normalize_route_ids(route_ids)
        if requested:
            station_route_ids = await self.repository.get_route_ids(station_id)
            missing = [route_id for route_id in requested if route_id not in station_route_ids]
            if missing:
                raise AppError(ErrorCode.ROUTE_NOT_FOUND, "정류소에서 요청한 노선을 찾을 수 없습니다.", 404)

        cache_namespace = getattr(self.client, "cache_namespace", "live")
        cache_key = f"station:{station_id}:arrivals:{cache_namespace}"
        cached = await self.cache.get_json(cache_key)
        if cached is not None:
            logger.info("arrival_cache_hit", station_id=station_id, action="get_arrivals")
            response = ArrivalsResponse.model_validate(cached)
        else:
            logger.info("arrival_cache_miss", station_id=station_id, action="get_arrivals")
            station_routes = await self.repository.get_routes(station_id)
            route_names = {route.route_id: route.name for route in station_routes}
            upstream = await self.client.get_arrivals(station_id, route_names)
            response = ArrivalsResponse(
                station=ArrivalStation(station_id=station.station_id, name=station.name),
                updated_at=upstream.updated_at,
                fetched_at=upstream.fetched_at,
                arrivals=upstream.arrivals,
            )
            await self.cache.set_json(cache_key, response.model_dump(mode="json"))

        if not requested:
            return response
        by_route = {arrival.route_id: arrival for arrival in response.arrivals}
        filtered: list[RouteArrival] = [by_route[route_id] for route_id in requested if route_id in by_route]
        missing_upstream = [route_id for route_id in requested if route_id not in by_route]
        if missing_upstream:
            routes_by_id = {route.route_id: route for route in await self.repository.get_routes(station_id)}
            filtered.extend(
                RouteArrival(route_id=route_id, route_name=routes_by_id[route_id].name, predictions=[])
                for route_id in missing_upstream
            )
        return response.model_copy(update={"arrivals": filtered})

    @staticmethod
    def _normalize_route_ids(route_ids: list[str] | None) -> list[str]:
        if not route_ids:
            return []
        normalized: list[str] = []
        for value in route_ids:
            route_id = value.strip()
            if route_id and route_id not in normalized:
                normalized.append(route_id)
        if len(normalized) > 4:
            raise AppError(ErrorCode.INVALID_REQUEST, "노선은 최대 4개까지 요청할 수 있습니다.", 400)
        return normalized
