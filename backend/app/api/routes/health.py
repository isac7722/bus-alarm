from __future__ import annotations

from fastapi import APIRouter, Request
from sqlalchemy import text

from app.api.dependencies import DatabaseSession

router = APIRouter(tags=["health"])


@router.get("/health")
async def health(request: Request, session: DatabaseSession) -> dict[str, str]:
    """Verify the API and its required database/cache dependencies."""
    await session.execute(text("SELECT 1"))
    await request.app.state.cache.ping()
    return {"status": "ok"}
