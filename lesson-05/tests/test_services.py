"""Direct connectivity tests that bypass the API and talk to the services."""
from __future__ import annotations

import os

import asyncpg
import redis.asyncio as aioredis

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://qatp:qatp@localhost:5432/qatp")
REDIS_URL = os.environ.get("REDIS_URL", "redis://localhost:6379/0")


async def test_postgres_accepts_queries() -> None:
    """Run SELECT 1 against Postgres and expect 1 back."""
    conn = await asyncpg.connect(DATABASE_URL, timeout=3)
    try:
        assert await conn.fetchval("SELECT 1") == 1
    finally:
        await conn.close()


async def test_redis_round_trip() -> None:
    """Write a key to Redis and read the same value back."""
    client = aioredis.from_url(REDIS_URL, decode_responses=True)
    try:
        await client.set("qatp:ci", "ok", ex=30)
        assert await client.get("qatp:ci") == "ok"
    finally:
        await client.aclose()
