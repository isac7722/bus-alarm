from __future__ import annotations

import re
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta, timezone
from xml.etree import ElementTree

import httpx
import structlog

from app.core.config import Settings
from app.core.exceptions import AppError, ErrorCode
from app.schemas.arrival import ArrivalPrediction, RouteArrival, VehicleStatus

KOREA_TIMEZONE = timezone(timedelta(hours=9))
REMAINING_STOPS_PATTERN = re.compile(r"\[(\d+)번째 전\]")
WAITING_MESSAGES = ("출발대기", "운행대기", "첫차대기")
UNAVAILABLE_MESSAGES = ("운행종료", "정보없음", "도착정보없음", "막차운행종료")

logger = structlog.get_logger(__name__)


@dataclass(frozen=True, slots=True)
class SeoulArrivalResult:
    """Normalized upstream response before station metadata is attached."""

    updated_at: datetime
    fetched_at: datetime
    arrivals: list[RouteArrival]


class SeoulBusClient:
    """HTTP client isolated from the rest of the application."""

    cache_namespace = "live"

    def __init__(self, settings: Settings, http_client: httpx.AsyncClient | None = None) -> None:
        """Initialize the client with safe settings and an optional test transport."""
        timeout = httpx.Timeout(
            timeout=settings.http_timeout_seconds,
            connect=settings.http_timeout_seconds,
            read=settings.http_timeout_seconds,
            write=settings.http_timeout_seconds,
            pool=settings.http_timeout_seconds,
        )
        self.settings = settings
        self._owns_client = http_client is None
        self.http_client = http_client or httpx.AsyncClient(timeout=timeout)

    async def close(self) -> None:
        """Close the underlying client when it is owned by this instance."""
        if self._owns_client:
            await self.http_client.aclose()

    async def get_arrivals(
        self,
        station_id: str,
        _route_names: Mapping[str, str] | None = None,
    ) -> SeoulArrivalResult:
        """Fetch every route arrival for one ARS station identifier."""
        started_at = datetime.now(UTC)
        try:
            response = await self.http_client.get(
                f"{self.settings.seoul_bus_api_base_url}/getStationByUid",
                params={
                    "serviceKey": self.settings.seoul_bus_api_key.get_secret_value(),
                    "arsId": station_id,
                },
            )
            response.raise_for_status()
        except httpx.TimeoutException as error:
            logger.error("seoul_bus_timeout", station_id=station_id)
            raise AppError(
                ErrorCode.SEOUL_BUS_API_TIMEOUT,
                "버스 정보 조회 시간이 초과되었습니다.",
                504,
            ) from error
        except httpx.HTTPError as error:
            logger.error("seoul_bus_http_error", station_id=station_id, error_type=type(error).__name__)
            raise AppError(
                ErrorCode.SEOUL_BUS_API_ERROR,
                "버스 정보를 일시적으로 조회할 수 없습니다.",
                502,
            ) from error

        result = self._parse_arrivals(response.content, fetched_at=datetime.now(UTC))
        logger.info(
            "seoul_bus_success",
            station_id=station_id,
            route_count=len(result.arrivals),
            latency_ms=int((datetime.now(UTC) - started_at).total_seconds() * 1000),
        )
        return result

    def _parse_arrivals(self, payload: bytes, fetched_at: datetime) -> SeoulArrivalResult:
        """Parse and normalize Seoul's XML response."""
        try:
            root = ElementTree.fromstring(payload)
        except ElementTree.ParseError as error:
            raise AppError(
                ErrorCode.SEOUL_BUS_API_ERROR,
                "버스 정보 응답을 처리할 수 없습니다.",
                502,
            ) from error

        header_code = self._text(root, ".//msgHeader/headerCd") or self._text(root, ".//headerCd")
        header_message = self._text(root, ".//msgHeader/headerMsg") or self._text(root, ".//headerMsg")
        if header_code not in (None, "0"):
            logger.warning("seoul_bus_api_error", header_code=header_code, header_message=header_message)
            raise AppError(
                ErrorCode.SEOUL_BUS_API_ERROR,
                "버스 정보를 일시적으로 조회할 수 없습니다.",
                502,
            )

        items = root.findall(".//msgBody/itemList") or root.findall(".//itemList")
        if not items:
            return SeoulArrivalResult(updated_at=fetched_at, fetched_at=fetched_at, arrivals=[])

        parsed_updated_at = [self._parse_mktime(self._text(item, "mkTm")) for item in items]
        updated_at = max((value for value in parsed_updated_at if value is not None), default=fetched_at)
        arrivals = [self._parse_route(item, updated_at) for item in items]
        arrivals.sort(key=lambda arrival: (arrival.route_name, arrival.route_id))
        return SeoulArrivalResult(updated_at=updated_at, fetched_at=fetched_at, arrivals=arrivals)

    def _parse_route(self, item: ElementTree.Element, updated_at: datetime) -> RouteArrival:
        route_id = self._text(item, "busRouteId") or ""
        if not route_id:
            raise AppError(
                ErrorCode.SEOUL_BUS_API_ERROR,
                "버스 정보 응답에 필수 값이 없습니다.",
                502,
            )
        route_name = self._text(item, "rtNm") or self._text(item, "busRouteAbrv") or route_id
        predictions = [self._parse_prediction(item, order, updated_at) for order in (1, 2)]
        meaningful = [
            prediction for prediction in predictions if self._is_meaningful(prediction, order=prediction.order)
        ]
        if not meaningful:
            meaningful = [predictions[0]]
        return RouteArrival(route_id=route_id, route_name=route_name, predictions=meaningful)

    def _parse_prediction(
        self,
        item: ElementTree.Element,
        order: int,
        updated_at: datetime,
    ) -> ArrivalPrediction:
        message = (self._text(item, f"arrmsg{order}") or "").replace(" ", "")
        remaining_seconds = self._nonnegative_int(self._text(item, f"traTime{order}"))
        vehicle_id = self._text(item, f"vehId{order}")
        status = self._vehicle_status(message, remaining_seconds, vehicle_id)
        if status == VehicleStatus.WAITING:
            remaining_seconds = None
        arrival_at = updated_at + timedelta(seconds=remaining_seconds) if remaining_seconds is not None else None
        remaining_stops = self._remaining_stops(item, message, order)
        return ArrivalPrediction(
            order=order,
            arrival_at=arrival_at,
            remaining_seconds=remaining_seconds,
            remaining_stops=remaining_stops,
            vehicle_status=status,
        )

    @staticmethod
    def _is_meaningful(prediction: ArrivalPrediction, order: int) -> bool:
        return order == 1 or prediction.vehicle_status not in {VehicleStatus.NOT_AVAILABLE, VehicleStatus.UNKNOWN}

    @classmethod
    def _remaining_stops(cls, item: ElementTree.Element, message: str, order: int) -> int | None:
        station_order = cls._nonnegative_int(cls._text(item, "staOrd"))
        section_order = cls._nonnegative_int(cls._text(item, f"sectOrd{order}"))
        if station_order is not None and section_order is not None and station_order >= section_order:
            return station_order - section_order
        match = REMAINING_STOPS_PATTERN.search(message)
        return int(match.group(1)) if match else None

    @staticmethod
    def _vehicle_status(message: str, remaining_seconds: int | None, vehicle_id: str | None) -> VehicleStatus:
        if any(token in message for token in WAITING_MESSAGES):
            return VehicleStatus.WAITING
        if any(token in message for token in UNAVAILABLE_MESSAGES):
            return VehicleStatus.NOT_AVAILABLE
        if remaining_seconds is not None and (remaining_seconds > 0 or vehicle_id not in (None, "", "0")):
            return VehicleStatus.RUNNING
        return VehicleStatus.NOT_AVAILABLE if not message or message == "-" else VehicleStatus.UNKNOWN

    @staticmethod
    def _parse_mktime(value: str | None) -> datetime | None:
        if not value:
            return None
        normalized = value.strip().split(".")[0]
        for pattern in ("%Y-%m-%d %H:%M:%S", "%Y%m%d%H%M%S"):
            try:
                return datetime.strptime(normalized, pattern).replace(tzinfo=KOREA_TIMEZONE)
            except ValueError:
                continue
        return None

    @staticmethod
    def _nonnegative_int(value: str | None) -> int | None:
        if value in (None, ""):
            return None
        try:
            parsed = int(float(value))
        except ValueError:
            return None
        return parsed if parsed >= 0 else None

    @staticmethod
    def _text(element: ElementTree.Element, path: str) -> str | None:
        child = element.find(path)
        return child.text.strip() if child is not None and child.text else None
