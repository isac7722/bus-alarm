from __future__ import annotations

from enum import StrEnum


class ErrorCode(StrEnum):
    """Stable public API error codes."""

    INVALID_REQUEST = "INVALID_REQUEST"
    STATION_NOT_FOUND = "STATION_NOT_FOUND"
    ROUTE_NOT_FOUND = "ROUTE_NOT_FOUND"
    SEOUL_BUS_API_ERROR = "SEOUL_BUS_API_ERROR"
    SEOUL_BUS_API_TIMEOUT = "SEOUL_BUS_API_TIMEOUT"
    CACHE_ERROR = "CACHE_ERROR"
    RATE_LIMIT_EXCEEDED = "RATE_LIMIT_EXCEEDED"
    INTERNAL_SERVER_ERROR = "INTERNAL_SERVER_ERROR"


class AppError(Exception):
    """Expected application error with a safe client-facing message."""

    def __init__(self, code: ErrorCode, message: str, status_code: int) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.status_code = status_code
