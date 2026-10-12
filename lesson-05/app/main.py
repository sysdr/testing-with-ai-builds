"""QATP-App health slice from Lesson 2: the part of the backend CI exercises first."""
from __future__ import annotations

import os

import asyncpg
import redis.asyncio as aioredis
from fastapi import FastAPI
from fastapi.responses import JSONResponse

# Module-level globals so tests can monkeypatch them to simulate an outage.
DATABASE_URL: str = os.environ.get("DATABASE_URL", "postgresql://qatp:qatp@localhost:5432/qatp")
REDIS_URL: str = os.environ.get("REDIS_URL", "redis://localhost:6379/0")

app = FastAPI(title="QATP-App")


async def check_db() -> str:
    """Return "connected" when Postgres answers SELECT 1, otherwise "unreachable"."""
    try:
        conn = await asyncpg.connect(DATABASE_URL, timeout=3)
    except Exception:
        return "unreachable"
    try:
        await conn.fetchval("SELECT 1")
    finally:
        await conn.close()
    return "connected"


async def check_redis() -> str:
    """Return "connected" when Redis answers PING, otherwise "unreachable"."""
    client = aioredis.from_url(REDIS_URL, socket_connect_timeout=3)
    try:
        await client.ping()
    except Exception:
        return "unreachable"
    finally:
        await client.aclose()
    return "connected"


@app.get("/health")
async def health() -> JSONResponse:
    """Report DB and Redis connectivity, returning 503 when either is down."""
    db_status = await check_db()
    redis_status = await check_redis()
    healthy = db_status == "connected" and redis_status == "connected"
    return JSONResponse(
        status_code=200 if healthy else 503,
        content={"db": db_status, "redis": redis_status},
    )
