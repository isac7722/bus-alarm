from __future__ import annotations

from sqlalchemy import Select, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.catalog import Route, RouteStop, Station


class StationRepository:
    """Read access to the normalized station catalog."""

    def __init__(self, session: AsyncSession) -> None:
        """Initialize the repository with a request-scoped session."""
        self.session = session

    async def search(self, keyword: str, limit: int = 20) -> list[Station]:
        """Search station names with deterministic exact-prefix-first ordering."""
        escaped = keyword.replace("%", r"\%").replace("_", r"\_")
        contains = f"%{escaped}%"
        prefix = f"{escaped}%"
        statement = (
            select(Station)
            .where(Station.name.ilike(contains, escape="\\"))
            .order_by(
                func.lower(Station.name).like(func.lower(prefix)).desc(),
                func.length(Station.name),
                Station.name,
                Station.station_id,
            )
            .limit(limit)
        )
        return list((await self.session.scalars(statement)).all())

    async def get(self, station_id: str) -> Station | None:
        """Return a station by ARS ID."""
        return await self.session.get(Station, station_id)

    async def get_routes(self, station_id: str) -> list[Route]:
        """Return routes through a station sorted by their display name."""
        statement: Select[tuple[Route]] = (
            select(Route)
            .join(RouteStop, RouteStop.route_id == Route.route_id)
            .where(RouteStop.station_id == station_id)
            .distinct()
            .order_by(Route.name, Route.route_id)
        )
        return list((await self.session.scalars(statement)).all())

    async def get_route_ids(self, station_id: str) -> set[str]:
        """Return route IDs that pass through a station."""
        statement = select(RouteStop.route_id).where(RouteStop.station_id == station_id)
        return set((await self.session.scalars(statement)).all())
