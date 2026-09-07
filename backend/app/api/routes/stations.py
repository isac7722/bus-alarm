from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Path, Query

from app.api.dependencies import StationServiceDependency
from app.schemas.error import ErrorResponse
from app.schemas.station import StationDetailResponse, StationSearchResponse

router = APIRouter(prefix="/stations", tags=["stations"])


@router.get(
    "/search",
    response_model=StationSearchResponse,
    responses={400: {"model": ErrorResponse}, 429: {"model": ErrorResponse}},
)
async def search_stations(
    service: StationServiceDependency,
    q: Annotated[str, Query(max_length=60)] = "",
) -> StationSearchResponse:
    """Search the local Seoul station catalog."""
    return await service.search(q)


@router.get(
    "/{station_id}",
    response_model=StationDetailResponse,
    responses={404: {"model": ErrorResponse}, 429: {"model": ErrorResponse}},
)
async def get_station(
    service: StationServiceDependency,
    station_id: Annotated[str, Path(pattern=r"^\d{5}$")],
) -> StationDetailResponse:
    """Return station metadata and passing routes."""
    return await service.detail(station_id)
