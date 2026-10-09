"""Postgres pool, Redis client, schema bootstrap, and FastAPI dependencies."""
import asyncpg
from fastapi import Request
from redis.asyncio import Redis

from app.config import settings

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    id            SERIAL PRIMARY KEY,
    email         TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS products (
    id          SERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    price_cents INTEGER NOT NULL CHECK (price_cents >= 0),
    stock       INTEGER NOT NULL CHECK (stock >= 0)
);
CREATE TABLE IF NOT EXISTS orders (
    id          SERIAL PRIMARY KEY,
    user_id     INTEGER NOT NULL REFERENCES users(id),
    product_id  INTEGER NOT NULL REFERENCES products(id),
    quantity    INTEGER NOT NULL CHECK (quantity > 0),
    total_cents INTEGER NOT NULL,
    status      TEXT NOT NULL DEFAULT 'pending',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
"""

SEED_PRODUCTS: list[tuple[str, str, int, int]] = [
    ("Mechanical Keyboard", "Hot-swappable 75% board with tactile switches", 8900, 500),
    ("USB-C Dock", "Eleven-port dock with dual display output", 12900, 500),
    ("Laptop Stand", "Aluminium stand with adjustable height", 4500, 500),
    ("Noise-Cancelling Headset", "Over-ear headset with boom microphone", 15900, 500),
    ("Webcam 1080p", "Fixed-focus webcam with privacy shutter", 5900, 500),
]


async def create_pool() -> asyncpg.Pool:
    """Open the shared asyncpg connection pool."""
    return await asyncpg.create_pool(
        settings.database_url, min_size=2, max_size=10, command_timeout=5
    )


def create_redis() -> Redis:
    """Build the Redis client with short timeouts so failures surface fast."""
    return Redis.from_url(
        settings.redis_url,
        decode_responses=True,
        socket_connect_timeout=2,
        socket_timeout=2,
    )


async def init_schema(pool: asyncpg.Pool) -> None:
    """Create tables if absent and seed products on first boot."""
    async with pool.acquire() as conn:
        await conn.execute(SCHEMA)
        count = await conn.fetchval("SELECT count(*) FROM products")
        if count == 0:
            await conn.executemany(
                "INSERT INTO products (name, description, price_cents, stock) "
                "VALUES ($1, $2, $3, $4)",
                SEED_PRODUCTS,
            )


def get_pool(request: Request) -> asyncpg.Pool:
    """Return the pool stored on application state."""
    return request.app.state.pool


def get_redis(request: Request) -> Redis:
    """Return the Redis client stored on application state."""
    return request.app.state.redis
