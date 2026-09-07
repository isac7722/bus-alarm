from __future__ import annotations

import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import structlog
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from redis.asyncio import Redis
from sqlalchemy import text
from starlette.middleware.base import RequestResponseEndpoint
from starlette.responses import Response

from app.api.router import api_router
from app.api.routes.health import router as health_router
from app.cache.cache import RedisCache
from app.cache.rate_limit import RedisRateLimiter
from app.clients.mock_seoul_bus_client import MockSeoulBusClient
from app.clients.seoul_bus_client import SeoulBusClient
from app.core.config import get_settings
from app.core.database import async_session_factory, engine
from app.core.exceptions import AppError, ErrorCode
from app.core.logging import configure_logging

configure_logging()
logger = structlog.get_logger(__name__)
settings = get_settings()


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Create required resources and fail fast when infrastructure is unavailable."""
    redis = Redis.from_url(settings.redis_url, decode_responses=True)
    cache = RedisCache(redis, settings.cache_ttl_seconds)
    client = MockSeoulBusClient() if settings.mock_arrivals else SeoulBusClient(settings)
    app.state.cache = cache
    app.state.rate_limiter = RedisRateLimiter(
        redis,
        requests=settings.rate_limit_requests,
        window_seconds=settings.rate_limit_window_seconds,
    )
    app.state.seoul_bus_client = client
    async with async_session_factory() as session:
        await session.execute(text("SELECT 1"))
    await cache.ping()
    logger.info("application_started", app_env=settings.app_env, mock_arrivals=settings.mock_arrivals)
    try:
        yield
    finally:
        await client.close()
        await cache.close()
        await engine.dispose()
        logger.info("application_stopped")


def create_app() -> FastAPI:
    """Create and configure the FastAPI application."""
    application = FastAPI(title=settings.app_name, version="1.0.0", lifespan=lifespan)
    if settings.cors_origins:
        application.add_middleware(
            CORSMiddleware,
            allow_origins=settings.cors_origins,
            allow_credentials=False,
            allow_methods=["GET"],
            allow_headers=["*"],
        )

    @application.middleware("http")
    async def request_middleware(request: Request, call_next: RequestResponseEndpoint) -> Response:
        started = time.perf_counter()
        if request.url.path.startswith(settings.api_v1_prefix):
            limiter: RedisRateLimiter | None = getattr(request.app.state, "rate_limiter", None)
            if limiter is not None:
                identity = request.client.host if request.client else "unknown"
                try:
                    result = await limiter.check(identity)
                except AppError as error:
                    return JSONResponse(
                        status_code=error.status_code,
                        content={"error": {"code": error.code, "message": error.message}},
                    )
                if not result.allowed:
                    rate_limit_response = JSONResponse(
                        status_code=429,
                        content={
                            "error": {
                                "code": ErrorCode.RATE_LIMIT_EXCEEDED,
                                "message": "요청이 너무 많습니다. 잠시 후 다시 시도해 주세요.",
                            }
                        },
                        headers={"Retry-After": str(result.retry_after)},
                    )
                    return rate_limit_response
        response = await call_next(request)
        logger.info(
            "request_completed",
            method=request.method,
            path=request.url.path,
            status_code=response.status_code,
            latency_ms=round((time.perf_counter() - started) * 1000, 2),
        )
        return response

    @application.exception_handler(AppError)
    async def app_error_handler(_request: Request, error: AppError) -> JSONResponse:
        return JSONResponse(
            status_code=error.status_code,
            content={"error": {"code": error.code, "message": error.message}},
        )

    @application.exception_handler(RequestValidationError)
    async def validation_error_handler(_request: Request, _error: RequestValidationError) -> JSONResponse:
        return JSONResponse(
            status_code=400,
            content={"error": {"code": ErrorCode.INVALID_REQUEST, "message": "요청 형식이 올바르지 않습니다."}},
        )

    @application.exception_handler(Exception)
    async def unexpected_error_handler(request: Request, error: Exception) -> JSONResponse:
        logger.exception("unhandled_error", path=request.url.path, error_type=type(error).__name__)
        return JSONResponse(
            status_code=500,
            content={
                "error": {
                    "code": ErrorCode.INTERNAL_SERVER_ERROR,
                    "message": "서버 오류가 발생했습니다.",
                }
            },
        )

    application.include_router(health_router)
    application.include_router(api_router, prefix=settings.api_v1_prefix)
    return application


app = create_app()
