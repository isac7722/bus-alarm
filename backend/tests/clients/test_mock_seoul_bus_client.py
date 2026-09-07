from __future__ import annotations

import pytest

from app.clients.mock_seoul_bus_client import MockSeoulBusClient
from app.schemas.arrival import VehicleStatus


@pytest.mark.asyncio
async def test_mock_client_generates_two_predictions_for_each_route() -> None:
    client = MockSeoulBusClient()

    result = await client.get_arrivals(
        "01532",
        {"100900004": "종로07", "100900005": "종로08"},
    )

    assert [arrival.route_name for arrival in result.arrivals] == ["종로07", "종로08"]
    assert all(len(arrival.predictions) == 2 for arrival in result.arrivals)
    assert result.arrivals[0].predictions[0].remaining_seconds == 90
    assert result.arrivals[1].predictions[0].remaining_seconds == 165
    assert all(
        prediction.vehicle_status == VehicleStatus.RUNNING
        for arrival in result.arrivals
        for prediction in arrival.predictions
    )
