from __future__ import annotations

from pathlib import Path

import pytest
from openpyxl import Workbook
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.commands.import_stations import CatalogImportError, persist_catalog, read_catalog
from app.models.catalog import Route, RouteStop, Station


def write_catalog(path: Path, headers: tuple[str, ...] | None = None) -> None:
    """Create a minimal import workbook."""
    workbook = Workbook()
    worksheet = workbook.active
    worksheet.title = "Data"
    worksheet.append(headers or ("ROUTE_ID", "노선명", "순번", "NODE_ID", "ARS_ID", "정류소명", "X좌표", "Y좌표"))
    worksheet.append(("100100341", "341", 1, "121000001", "01136", "하림각", 126.9617, 37.5981))
    worksheet.append(("200000001", "경기1", 2, "221000001", "01136", "경기정류소", 127.0, 37.5))
    workbook.save(path)


@pytest.mark.asyncio
async def test_read_and_persist_catalog_preserves_leading_zero(tmp_path: Path, session: AsyncSession) -> None:
    path = tmp_path / "stations.xlsx"
    write_catalog(path)

    catalog = read_catalog(path)
    await persist_catalog(session, catalog)
    await persist_catalog(session, catalog)

    assert catalog.stations[0]["station_id"] == "01136"
    assert catalog.skipped_non_seoul_rows == 1
    assert await session.scalar(select(func.count()).select_from(Station)) == 1
    assert await session.scalar(select(func.count()).select_from(Route)) == 1
    assert await session.scalar(select(func.count()).select_from(RouteStop)) == 1


def test_read_catalog_rejects_unexpected_headers(tmp_path: Path) -> None:
    path = tmp_path / "stations.xlsx"
    write_catalog(path, headers=("bad",) * 8)

    with pytest.raises(CatalogImportError, match="Unexpected headers"):
        read_catalog(path)
