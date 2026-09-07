from __future__ import annotations

from collections.abc import Mapping
from datetime import UTC, datetime, timedelta

import structlog

from app.clients.seoul_bus_client import SeoulArrivalResult
from app.schemas.arrival import ArrivalPrediction, RouteArrival, VehicleStatus

logger = structlog.get_logger(__name__)


class MockSeoulBusClient:
    """Generate deterministic-looking arrivals without calling Seoul's API."""

    cache_namespace = "mock"

    async def close(self) -> None:
        """Keep the same lifecycle interface as the live client."""

    async def get_arrivals(
        self,
        station_id: str,
        route_names: Mapping[str, str] | None = None,
    ) -> SeoulArrivalResult:
        """Return two running vehicles for every route at the station."""
        now = datetime.now(UTC).replace(microsecond=0)
        arrivals = [
            self._build_route(route_id, route_name, index, now)
            for index, (route_id, route_name) in enumerate((route_names or {}).items())
        ]
        logger.info("mock_arrivals_generated", station_id=station_id, route_count=len(arrivals))
        return SeoulArrivalResult(updated_at=now, fetched_at=now, arrivals=arrivals)

    @staticmethod
    def _build_route(route_id: str, route_name: str, index: int, now: datetime) -> RouteArrival:
        first_seconds = 90 + (index % 4) * 75
        second_seconds = first_seconds + 450
        return RouteArrival(
            route_id=route_id,
            route_name=route_name,
            predictions=[
                ArrivalPrediction(
                    order=1,
                    arrival_at=now + timedelta(seconds=first_seconds),
                    remaining_seconds=first_seconds,
                    remaining_stops=1 + (index % 4),
                    vehicle_status=VehicleStatus.RUNNING,
                ),
                ArrivalPrediction(
                    order=2,
                    arrival_at=now + timedelta(seconds=second_seconds),
                    remaining_seconds=second_seconds,
                    remaining_stops=6 + (index % 4),
                    vehicle_status=VehicleStatus.RUNNING,
                ),
            ],
        )
