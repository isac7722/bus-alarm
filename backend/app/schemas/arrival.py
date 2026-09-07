from __future__ import annotations

from datetime import datetime
from enum import StrEnum

from pydantic import BaseModel, Field


class VehicleStatus(StrEnum):
    """Normalized status of an arrival prediction."""

    RUNNING = "RUNNING"
    WAITING = "WAITING"
    NOT_AVAILABLE = "NOT_AVAILABLE"
    UNKNOWN = "UNKNOWN"


class ArrivalPrediction(BaseModel):
    """One predicted arriving vehicle for a route."""

    order: int = Field(ge=1, le=2)
    arrival_at: datetime | None
    remaining_seconds: int | None = Field(default=None, ge=0)
    remaining_stops: int | None = Field(default=None, ge=0)
    vehicle_status: VehicleStatus


class RouteArrival(BaseModel):
    """Up to two arrival predictions for a single route."""

    route_id: str
    route_name: str
    predictions: list[ArrivalPrediction] = Field(max_length=2)


class ArrivalStation(BaseModel):
    """Minimal station metadata in an arrival response."""

    station_id: str
    name: str


class ArrivalsResponse(BaseModel):
    """Normalized station arrival response."""

    station: ArrivalStation
    updated_at: datetime
    fetched_at: datetime
    arrivals: list[RouteArrival]
