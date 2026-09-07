from __future__ import annotations

from collections.abc import AsyncIterator

import pytest
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.database import Base
from app.models.catalog import Route, RouteStop, Station


@pytest.fixture
async def session() -> AsyncIterator[AsyncSession]:
    """Provide an isolated in-memory catalog database."""
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as connection:
        await connection.run_sync(Base.metadata.create_all)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with factory() as database_session:
        yield database_session
    await engine.dispose()


@pytest.fixture
async def seeded_session(session: AsyncSession) -> AsyncSession:
    """Seed one station and two routes."""
    session.add(
        Station(
            station_id="22001",
            node_id="121000001",
            name="강남역",
            longitude=127.0276,
            latitude=37.4979,
        )
    )
    session.add_all(
        [
            Route(route_id="100100341", name="341"),
            Route(route_id="100100360", name="360"),
        ]
    )
    session.add_all(
        [
            RouteStop(route_id="100100341", station_id="22001", sequence=10),
            RouteStop(route_id="100100360", station_id="22001", sequence=12),
        ]
    )
    await session.commit()
    return session
