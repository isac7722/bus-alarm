from __future__ import annotations

from pydantic import BaseModel, Field


def format_ars_id(station_id: str) -> str:
    """Format a five-digit ARS identifier for display."""
    normalized = station_id.zfill(5)
    return f"{normalized[:2]}-{normalized[2:]}"


class StationSummary(BaseModel):
    """Normalized station data returned to iOS."""

    station_id: str = Field(pattern=r"^\d{5}$")
    ars_id: str
    name: str
    direction: str | None = None
    latitude: float
    longitude: float


class RouteSummary(BaseModel):
    """A bus route available at a station."""

    route_id: str
    route_name: str


class StationSearchResponse(BaseModel):
    """Station search result envelope."""

    stations: list[StationSummary]


class StationDetailResponse(BaseModel):
    """Station details and all routes passing through it."""

    station: StationSummary
    routes: list[RouteSummary]
