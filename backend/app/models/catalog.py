from __future__ import annotations

from sqlalchemy import Float, ForeignKey, Index, Integer, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base


class Station(Base):
    """A Seoul bus station identified by its five-digit ARS identifier."""

    __tablename__ = "stations"

    station_id: Mapped[str] = mapped_column(String(5), primary_key=True)
    node_id: Mapped[str] = mapped_column(String(9), nullable=False, index=True)
    name: Mapped[str] = mapped_column(String(128), nullable=False, index=True)
    longitude: Mapped[float] = mapped_column(Float, nullable=False)
    latitude: Mapped[float] = mapped_column(Float, nullable=False)
    route_stops: Mapped[list[RouteStop]] = relationship(back_populates="station")


class Route(Base):
    """A Seoul bus route."""

    __tablename__ = "routes"

    route_id: Mapped[str] = mapped_column(String(9), primary_key=True)
    name: Mapped[str] = mapped_column(String(128), nullable=False, index=True)
    route_stops: Mapped[list[RouteStop]] = relationship(back_populates="route")


class RouteStop(Base):
    """Ordered association between a route and a station."""

    __tablename__ = "route_stops"
    __table_args__ = (Index("ix_route_stops_station_id", "station_id"),)

    route_id: Mapped[str] = mapped_column(
        String(9), ForeignKey("routes.route_id", ondelete="CASCADE"), primary_key=True
    )
    sequence: Mapped[int] = mapped_column(Integer, primary_key=True)
    station_id: Mapped[str] = mapped_column(
        String(5), ForeignKey("stations.station_id", ondelete="CASCADE"), nullable=False
    )
    route: Mapped[Route] = relationship(back_populates="route_stops")
    station: Mapped[Station] = relationship(back_populates="route_stops")
