from fastapi import APIRouter

from app.api.routes import arrivals, stations

api_router = APIRouter()
api_router.include_router(stations.router)
api_router.include_router(arrivals.router)
