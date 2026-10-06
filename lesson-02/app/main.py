"""Application factory, lifespan wiring, and the dependency-aware health route."""
import asyncio
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import asyncpg
from fastapi import FastAPI, Request, Response, status
from fastapi.routing import APIRoute
from redis.asyncio import Redis

from app.db import create_pool, create_redis, init_schema
from app.routers import auth, orders, products
from app.schemas import HealthOut


def operation_id(route: APIRoute) -> str:
    """Use the function name as the operationId so it survives path renames."""
    return route.name


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Open the pool and Redis client on startup and close them on shutdown."""
    app.state.pool = await create_pool()
    app.state.redis = create_redis()
    await init_schema(app.state.pool)
    yield
    await app.state.pool.close()
    await app.state.redis.aclose()


app = FastAPI(
    title="QATP-App",
    version="0.2.0",
    description="Application under test for the Testing What AI Builds course.",
    lifespan=lifespan,
    generate_unique_id_function=operation_id,
)
app.include_router(auth.router)
app.include_router(products.router)
app.include_router(orders.router)


async def check_db(pool: asyncpg.Pool) -> str:
    """Return 'connected' if Postgres answers a trivial query within two seconds."""
    try:
        await asyncio.wait_for(pool.fetchval("SELECT 1"), timeout=2)
    except Exception:
        return "unreachable"
    return "connected"


async def check_redis(redis: Redis) -> str:
    """Return 'connected' if Redis answers PING within two seconds."""
    try:
        await asyncio.wait_for(redis.ping(), timeout=2)
    except Exception:
        return "unreachable"
    return "connected"


@app.get(
    "/health",
    response_model=HealthOut,
    responses={503: {"model": HealthOut}},
    tags=["ops"],
)
async def health(request: Request, response: Response) -> HealthOut:
    """Report 200 only when both Postgres and Redis answer."""
    db_state = await check_db(request.app.state.pool)
    redis_state = await check_redis(request.app.state.redis)
    healthy = db_state == "connected" and redis_state == "connected"
    if not healthy:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
    return HealthOut(
        status="ok" if healthy else "degraded", db=db_state, redis=redis_state
    )
