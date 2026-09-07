from __future__ import annotations

from typing import Annotated

from fastapi import Depends, Request
from sqlalchemy.ext.asyncio import AsyncSession

from app.cache.cache import RedisCache
from app.clients.seoul_bus_client import SeoulBusClient
from app.core.database import get_database_session
from app.repositories.station_repository import StationRepository
from app.services.arrival_service import ArrivalService
from app.services.station_service import StationService

DatabaseSession = Annotated[AsyncSession, Depends(get_database_session)]


def get_station_service(session: DatabaseSession) -> StationService:
    """Build a request-scoped station service."""
    return StationService(StationRepository(session))


def get_arrival_service(request: Request, session: DatabaseSession) -> ArrivalService:
    """Build a request-scoped arrival service from app resources."""
    client: SeoulBusClient = request.app.state.seoul_bus_client
    cache: RedisCache = request.app.state.cache
    return ArrivalService(StationRepository(session), client, cache)


StationServiceDependency = Annotated[StationService, Depends(get_station_service)]
ArrivalServiceDependency = Annotated[ArrivalService, Depends(get_arrival_service)]
