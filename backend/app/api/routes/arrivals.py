from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Path, Query

from app.api.dependencies import ArrivalServiceDependency
from app.schemas.arrival import ArrivalsResponse
from app.schemas.error import ErrorResponse

router = APIRouter(prefix="/stations", tags=["arrivals"])


@router.get(
    "/{station_id}/arrivals",
    response_model=ArrivalsResponse,
    responses={
        400: {"model": ErrorResponse},
        404: {"model": ErrorResponse},
        429: {"model": ErrorResponse},
        502: {"model": ErrorResponse},
        503: {"model": ErrorResponse},
        504: {"model": ErrorResponse},
    },
)
async def get_arrivals(
    service: ArrivalServiceDependency,
    station_id: Annotated[str, Path(pattern=r"^\d{5}$")],
    route_ids: Annotated[str | None, Query(description="Comma-separated route IDs")] = None,
) -> ArrivalsResponse:
    """Return up to two vehicles for every requested route."""
    parsed_route_ids = route_ids.split(",") if route_ids is not None else None
    return await service.get_arrivals(station_id, parsed_route_ids)
