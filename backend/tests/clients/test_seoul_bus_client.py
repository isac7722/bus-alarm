from __future__ import annotations

from datetime import timedelta

import httpx
import pytest

from app.clients.seoul_bus_client import SeoulBusClient
from app.core.config import Settings
from app.core.exceptions import AppError, ErrorCode
from app.schemas.arrival import VehicleStatus


def test_settings_disable_mock_arrivals_by_default() -> None:
    assert Settings(_env_file=None).mock_arrivals is False


def successful_xml() -> bytes:
    """Return a representative two-vehicle Seoul response."""
    return b"""<?xml version="1.0" encoding="UTF-8"?>
    <ServiceResult>
      <msgHeader><headerCd>0</headerCd><headerMsg>OK</headerMsg></msgHeader>
      <msgBody>
        <itemList>
          <busRouteId>100100341</busRouteId><rtNm>341</rtNm>
          <mkTm>2026-08-12 09:27:00.0</mkTm><staOrd>10</staOrd>
          <arrmsg1>3\xeb\xb6\x84\xed\x9b\x84[2\xeb\xb2\x88\xec\xa7\xb8 \xec\xa0\x84]</arrmsg1><traTime1>180</traTime1><sectOrd1>8</sectOrd1><vehId1>1234</vehId1>
          <arrmsg2>10\xeb\xb6\x84\xed\x9b\x84[6\xeb\xb2\x88\xec\xa7\xb8 \xec\xa0\x84]</arrmsg2><traTime2>600</traTime2><sectOrd2>4</sectOrd2><vehId2>5678</vehId2>
        </itemList>
      </msgBody>
    </ServiceResult>"""


@pytest.mark.asyncio
async def test_get_arrivals_normalizes_two_predictions() -> None:
    transport = httpx.MockTransport(lambda _request: httpx.Response(200, content=successful_xml()))
    http_client = httpx.AsyncClient(transport=transport)
    client = SeoulBusClient(Settings(seoul_bus_api_key="secret"), http_client=http_client)

    result = await client.get_arrivals("22001")

    assert result.updated_at.isoformat() == "2026-08-12T09:27:00+09:00"
    assert len(result.arrivals) == 1
    predictions = result.arrivals[0].predictions
    assert [prediction.remaining_seconds for prediction in predictions] == [180, 600]
    assert [prediction.remaining_stops for prediction in predictions] == [2, 6]
    assert predictions[0].arrival_at == result.updated_at + timedelta(seconds=180)
    assert all(prediction.vehicle_status == VehicleStatus.RUNNING for prediction in predictions)
    await http_client.aclose()


@pytest.mark.asyncio
async def test_get_arrivals_maps_timeout() -> None:
    def timeout(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("timeout", request=request)

    http_client = httpx.AsyncClient(transport=httpx.MockTransport(timeout))
    client = SeoulBusClient(Settings(seoul_bus_api_key="secret"), http_client=http_client)

    with pytest.raises(AppError) as captured:
        await client.get_arrivals("22001")

    assert captured.value.code == ErrorCode.SEOUL_BUS_API_TIMEOUT
    assert captured.value.status_code == 504
    await http_client.aclose()


@pytest.mark.asyncio
async def test_get_arrivals_maps_http_error() -> None:
    transport = httpx.MockTransport(lambda _request: httpx.Response(500, content=b"upstream failed"))
    http_client = httpx.AsyncClient(transport=transport)
    client = SeoulBusClient(Settings(seoul_bus_api_key="secret"), http_client=http_client)

    with pytest.raises(AppError) as captured:
        await client.get_arrivals("22001")

    assert captured.value.code == ErrorCode.SEOUL_BUS_API_ERROR
    assert captured.value.status_code == 502
    await http_client.aclose()


@pytest.mark.asyncio
async def test_get_arrivals_rejects_malformed_xml() -> None:
    transport = httpx.MockTransport(lambda _request: httpx.Response(200, content=b"not xml"))
    http_client = httpx.AsyncClient(transport=transport)
    client = SeoulBusClient(Settings(seoul_bus_api_key="secret"), http_client=http_client)

    with pytest.raises(AppError) as captured:
        await client.get_arrivals("22001")

    assert captured.value.code == ErrorCode.SEOUL_BUS_API_ERROR
    await http_client.aclose()


@pytest.mark.asyncio
async def test_get_arrivals_rejects_api_error_code() -> None:
    payload = (
        b"<ServiceResult><msgHeader><headerCd>5</headerCd><headerMsg>timeout</headerMsg></msgHeader></ServiceResult>"
    )
    transport = httpx.MockTransport(lambda _request: httpx.Response(200, content=payload))
    http_client = httpx.AsyncClient(transport=transport)
    client = SeoulBusClient(Settings(seoul_bus_api_key="secret"), http_client=http_client)

    with pytest.raises(AppError) as captured:
        await client.get_arrivals("22001")

    assert captured.value.status_code == 502
    await http_client.aclose()


@pytest.mark.asyncio
async def test_get_arrivals_rejects_missing_route_id() -> None:
    payload = b"""
    <ServiceResult>
      <msgHeader><headerCd>0</headerCd></msgHeader>
      <msgBody><itemList><rtNm>341</rtNm><mkTm>2026-08-12 09:27:00.0</mkTm></itemList></msgBody>
    </ServiceResult>
    """
    http_client = httpx.AsyncClient(
        transport=httpx.MockTransport(lambda _request: httpx.Response(200, content=payload))
    )
    client = SeoulBusClient(Settings(seoul_bus_api_key="secret"), http_client=http_client)

    with pytest.raises(AppError) as captured:
        await client.get_arrivals("22001")

    assert captured.value.code == ErrorCode.SEOUL_BUS_API_ERROR
    assert captured.value.status_code == 502
    await http_client.aclose()
