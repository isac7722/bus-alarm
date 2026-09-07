from __future__ import annotations

from functools import lru_cache

from pydantic import Field, SecretStr, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Environment-backed application settings."""

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    app_env: str = "local"
    app_name: str = "BusWidget API"
    api_v1_prefix: str = "/api/v1"
    mock_arrivals: bool = False
    seoul_bus_api_key: SecretStr = SecretStr("")
    seoul_bus_api_base_url: str = "http://ws.bus.go.kr/api/rest/stationinfo"
    database_url: str = "postgresql+asyncpg://buswidget:buswidget@localhost:5432/buswidget"
    redis_url: str = "redis://localhost:6379/0"
    cache_ttl_seconds: int = Field(default=30, ge=1, le=300)
    http_timeout_seconds: float = Field(default=5, gt=0, le=30)
    rate_limit_requests: int = Field(default=60, ge=1)
    rate_limit_window_seconds: int = Field(default=60, ge=1)
    station_catalog_path: str = "../seoul_bus_statiosn.xlsx"
    cors_origins: list[str] = []

    @field_validator("seoul_bus_api_base_url")
    @classmethod
    def strip_base_url(cls, value: str) -> str:
        """Normalize the external service base URL."""
        return value.rstrip("/")


@lru_cache
def get_settings() -> Settings:
    """Return the singleton application settings."""
    return Settings()
