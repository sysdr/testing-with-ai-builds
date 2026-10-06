#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

LESSON_DIR="lesson-02"
COMPOSE=(docker compose -f "${LESSON_DIR}/docker-compose.yml")

echo -e "${BOLD}${CYAN}════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Module 0 — Build Before You Test${RESET}"
echo -e "${BOLD}  Lesson 2 — QATP-App: The Backend${RESET}"
echo -e "${BOLD}  Day 2 of 90${RESET}"
echo -e "${BOLD}${CYAN}════════════════════════════════════════════════${RESET}"

# ── Directory structure ──────────────────────────────────────────
mkdir -p "${LESSON_DIR}/app/routers" "${LESSON_DIR}/tests" "${LESSON_DIR}/reports"
echo -e "${GREEN}✓${RESET} Created ${LESSON_DIR}/ directory tree"

# ── requirements.txt ─────────────────────────────────────────────
cat > "${LESSON_DIR}/requirements.txt" << 'EOF'
fastapi==0.115.0
uvicorn[standard]==0.30.6
asyncpg==0.29.0
redis==5.0.8
python-jose[cryptography]==3.3.0
bcrypt==4.2.0
pytest==8.3.3
httpx==0.27.2
EOF

# ── Dockerfile ───────────────────────────────────────────────────
cat > "${LESSON_DIR}/Dockerfile" << 'EOF'
FROM python:3.11-slim
WORKDIR /app
# Install dependencies first so code edits do not invalidate this layer
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
# Tests ship in the image so `make test` needs no Python on the host
COPY tests ./tests
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF

# ── docker-compose.yml ───────────────────────────────────────────
cat > "${LESSON_DIR}/docker-compose.yml" << 'EOF'
name: qatp-lesson-02

services:
  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: qatp
      POSTGRES_PASSWORD: qatp
      POSTGRES_DB: qatp
    healthcheck:
      # pg_isready succeeds only once Postgres accepts connections,
      # which is several seconds after the container reports "running"
      test: ["CMD-SHELL", "pg_isready -U qatp -d qatp"]
      interval: 2s
      timeout: 3s
      retries: 30

  redis:
    image: redis:7-alpine
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 2s
      timeout: 3s
      retries: 30

  api:
    build: .
    ports:
      - "8000:8000"
    environment:
      # Hostnames are compose service names, not localhost
      DATABASE_URL: postgresql://qatp:qatp@db:5432/qatp
      REDIS_URL: redis://redis:6379/0
      # Local-only signing key; later modules scan for exactly this kind of default
      JWT_SECRET: dev-only-change-me
    depends_on:
      # service_healthy waits for the healthchecks above, not just container start
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      # urlopen raises on 503, so "healthy" means both dependencies answered
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"]
      interval: 3s
      timeout: 3s
      retries: 20
EOF

# ── app/__init__.py ──────────────────────────────────────────────
cat > "${LESSON_DIR}/app/__init__.py" << 'EOF'
"""QATP-App backend package."""
EOF

cat > "${LESSON_DIR}/app/routers/__init__.py" << 'EOF'
"""Route groups: auth, products, orders."""
EOF

# ── app/config.py ────────────────────────────────────────────────
cat > "${LESSON_DIR}/app/config.py" << 'EOF'
"""Runtime settings read once from environment variables."""
import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    """Immutable configuration for the API process."""

    database_url: str = os.getenv("DATABASE_URL", "postgresql://qatp:qatp@db:5432/qatp")
    redis_url: str = os.getenv("REDIS_URL", "redis://redis:6379/0")
    jwt_secret: str = os.getenv("JWT_SECRET", "dev-only-change-me")
    access_ttl: int = int(os.getenv("ACCESS_TTL_SECONDS", "900"))
    refresh_ttl: int = int(os.getenv("REFRESH_TTL_SECONDS", "604800"))


settings = Settings()
EOF

# ── app/db.py ────────────────────────────────────────────────────
cat > "${LESSON_DIR}/app/db.py" << 'EOF'
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
EOF

# ── app/schemas.py ───────────────────────────────────────────────
cat > "${LESSON_DIR}/app/schemas.py" << 'EOF'
"""Request and response models; these become the OpenAPI component schemas."""
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field

OrderStatus = Literal["pending", "paid", "shipped", "delivered", "cancelled"]


class Message(BaseModel):
    """Error or confirmation body shared by every route."""

    detail: str


class HealthOut(BaseModel):
    """Dependency status returned by /health."""

    status: Literal["ok", "degraded"]
    db: Literal["connected", "unreachable"]
    redis: Literal["connected", "unreachable"]


class Credentials(BaseModel):
    """Email and password for register and login."""

    email: str = Field(pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$", max_length=254)
    password: str = Field(min_length=6, max_length=72)


class TokenPair(BaseModel):
    """Access and refresh tokens issued together."""

    access_token: str
    refresh_token: str
    token_type: Literal["bearer"] = "bearer"


class RefreshRequest(BaseModel):
    """Body for /auth/refresh."""

    refresh_token: str


class UserOut(BaseModel):
    """Public view of a user."""

    id: int
    email: str


class ProductIn(BaseModel):
    """Fields required to create a product."""

    name: str = Field(min_length=1, max_length=120)
    description: str = Field(default="", max_length=2000)
    price_cents: int = Field(ge=0, le=10_000_000)
    stock: int = Field(ge=0, le=1_000_000)


class ProductUpdate(BaseModel):
    """Partial update; omitted fields keep their current value."""

    name: str | None = Field(default=None, min_length=1, max_length=120)
    description: str | None = Field(default=None, max_length=2000)
    price_cents: int | None = Field(default=None, ge=0, le=10_000_000)
    stock: int | None = Field(default=None, ge=0, le=1_000_000)


class ProductOut(BaseModel):
    """Product as stored."""

    id: int
    name: str
    description: str
    price_cents: int
    stock: int


class OrderIn(BaseModel):
    """Fields required to place an order."""

    product_id: int = Field(ge=1)
    quantity: int = Field(ge=1, le=100)


class OrderStatusUpdate(BaseModel):
    """Body for the status transition route."""

    status: OrderStatus


class OrderOut(BaseModel):
    """Order as stored."""

    id: int
    user_id: int
    product_id: int
    quantity: int
    total_cents: int
    status: OrderStatus
    created_at: datetime
EOF

# ── app/security.py ──────────────────────────────────────────────
cat > "${LESSON_DIR}/app/security.py" << 'EOF'
"""Password hashing, JWT issue and verify, and the auth dependencies."""
import time
import uuid
from typing import Any

import bcrypt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jose import JWTError, jwt
from redis.asyncio import Redis

from app.config import settings
from app.db import get_redis

ALGORITHM = "HS256"
bearer = HTTPBearer(auto_error=False)


def hash_password(password: str) -> str:
    """Return a bcrypt hash of the password."""
    return bcrypt.hashpw(password.encode(), bcrypt.gensalt(rounds=10)).decode()


def verify_password(password: str, password_hash: str) -> bool:
    """Check a password against its stored bcrypt hash."""
    return bcrypt.checkpw(password.encode(), password_hash.encode())


def create_token(user_id: int, kind: str, ttl_seconds: int) -> tuple[str, str]:
    """Sign a JWT of the given kind and return it with its jti."""
    jti = uuid.uuid4().hex
    now = int(time.time())
    claims = {
        "sub": str(user_id),
        "kind": kind,
        "jti": jti,
        "iat": now,
        "exp": now + ttl_seconds,
    }
    return jwt.encode(claims, settings.jwt_secret, algorithm=ALGORITHM), jti


def decode_token(token: str, expected_kind: str) -> dict[str, Any]:
    """Verify signature, expiry, and kind, or raise 401."""
    try:
        claims = jwt.decode(token, settings.jwt_secret, algorithms=[ALGORITHM])
    except JWTError as exc:
        raise HTTPException(
            status.HTTP_401_UNAUTHORIZED, "Invalid or expired token"
        ) from exc
    if claims.get("kind") != expected_kind:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Wrong token type")
    return claims


async def current_claims(
    creds: HTTPAuthorizationCredentials | None = Depends(bearer),
    redis: Redis = Depends(get_redis),
) -> dict[str, Any]:
    """Return access-token claims after checking the Redis denylist."""
    if creds is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Missing bearer token")
    claims = decode_token(creds.credentials, "access")
    if await redis.exists(f"denied:{claims['jti']}"):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Token revoked")
    return claims


async def current_user_id(claims: dict[str, Any] = Depends(current_claims)) -> int:
    """Return the authenticated user's id."""
    return int(claims["sub"])
EOF

# ── app/routers/auth.py ──────────────────────────────────────────
cat > "${LESSON_DIR}/app/routers/auth.py" << 'EOF'
"""Auth routes: register, login, refresh, logout, me."""
import time
from typing import Any

import asyncpg
from fastapi import APIRouter, Depends, HTTPException, status
from redis.asyncio import Redis

from app.config import settings
from app.db import get_pool, get_redis
from app.schemas import Credentials, Message, RefreshRequest, TokenPair, UserOut
from app.security import (
    create_token,
    current_claims,
    current_user_id,
    decode_token,
    hash_password,
    verify_password,
)

router = APIRouter(prefix="/auth", tags=["auth"])


async def issue_pair(redis: Redis, user_id: int) -> TokenPair:
    """Create an access and refresh token and record the refresh jti in Redis."""
    access, _ = create_token(user_id, "access", settings.access_ttl)
    refresh, refresh_jti = create_token(user_id, "refresh", settings.refresh_ttl)
    await redis.setex(f"refresh:{refresh_jti}", settings.refresh_ttl, str(user_id))
    return TokenPair(access_token=access, refresh_token=refresh)


@router.post(
    "/register",
    response_model=TokenPair,
    status_code=status.HTTP_201_CREATED,
    responses={409: {"model": Message}},
)
async def register(
    body: Credentials,
    pool: asyncpg.Pool = Depends(get_pool),
    redis: Redis = Depends(get_redis),
) -> TokenPair:
    """Create a user and return a token pair."""
    try:
        user_id = await pool.fetchval(
            "INSERT INTO users (email, password_hash) VALUES ($1, $2) RETURNING id",
            body.email.lower(),
            hash_password(body.password),
        )
    except asyncpg.UniqueViolationError as exc:
        raise HTTPException(
            status.HTTP_409_CONFLICT, "Email already registered"
        ) from exc
    return await issue_pair(redis, user_id)


@router.post("/login", response_model=TokenPair, responses={401: {"model": Message}})
async def login(
    body: Credentials,
    pool: asyncpg.Pool = Depends(get_pool),
    redis: Redis = Depends(get_redis),
) -> TokenPair:
    """Exchange valid credentials for a token pair."""
    row = await pool.fetchrow(
        "SELECT id, password_hash FROM users WHERE email = $1", body.email.lower()
    )
    if row is None or not verify_password(body.password, row["password_hash"]):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid email or password")
    return await issue_pair(redis, row["id"])


@router.post("/refresh", response_model=TokenPair, responses={401: {"model": Message}})
async def refresh(body: RefreshRequest, redis: Redis = Depends(get_redis)) -> TokenPair:
    """Rotate a refresh token: the old one is consumed, a new pair is issued."""
    claims = decode_token(body.refresh_token, "refresh")
    consumed = await redis.delete(f"refresh:{claims['jti']}")
    if consumed == 0:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Refresh token already used")
    return await issue_pair(redis, int(claims["sub"]))


@router.post("/logout", response_model=Message, responses={401: {"model": Message}})
async def logout(
    claims: dict[str, Any] = Depends(current_claims),
    redis: Redis = Depends(get_redis),
) -> Message:
    """Deny the presented access token for the rest of its lifetime."""
    remaining = max(int(claims["exp"]) - int(time.time()), 1)
    await redis.setex(f"denied:{claims['jti']}", remaining, "1")
    return Message(detail="Logged out")


@router.get(
    "/me",
    response_model=UserOut,
    responses={401: {"model": Message}, 404: {"model": Message}},
)
async def me(
    user_id: int = Depends(current_user_id),
    pool: asyncpg.Pool = Depends(get_pool),
) -> UserOut:
    """Return the authenticated user's profile."""
    row = await pool.fetchrow("SELECT id, email FROM users WHERE id = $1", user_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "User not found")
    return UserOut(**dict(row))
EOF

# ── app/routers/products.py ──────────────────────────────────────
cat > "${LESSON_DIR}/app/routers/products.py" << 'EOF'
"""Product routes: list, search, get, create, update, delete."""
import asyncpg
from fastapi import APIRouter, Depends, HTTPException, Query, Response, status

from app.db import get_pool
from app.schemas import Message, ProductIn, ProductOut, ProductUpdate
from app.security import current_user_id

router = APIRouter(prefix="/products", tags=["products"])

COLUMNS = "id, name, description, price_cents, stock"


@router.get("", response_model=list[ProductOut])
async def list_products(
    limit: int = Query(default=20, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
    pool: asyncpg.Pool = Depends(get_pool),
) -> list[ProductOut]:
    """Return one page of products ordered by id."""
    rows = await pool.fetch(
        f"SELECT {COLUMNS} FROM products ORDER BY id LIMIT $1 OFFSET $2", limit, offset
    )
    return [ProductOut(**dict(row)) for row in rows]


# Declared before /{product_id}: FastAPI matches routes in declaration order,
# and "search" would otherwise be parsed as an integer id and rejected with 422.
@router.get("/search", response_model=list[ProductOut])
async def search_products(
    q: str = Query(min_length=1, max_length=100),
    pool: asyncpg.Pool = Depends(get_pool),
) -> list[ProductOut]:
    """Return products whose name or description contains the query."""
    rows = await pool.fetch(
        f"SELECT {COLUMNS} FROM products "
        "WHERE name ILIKE $1 OR description ILIKE $1 ORDER BY id LIMIT 50",
        f"%{q}%",
    )
    return [ProductOut(**dict(row)) for row in rows]


@router.get("/{product_id}", response_model=ProductOut, responses={404: {"model": Message}})
async def get_product(
    product_id: int, pool: asyncpg.Pool = Depends(get_pool)
) -> ProductOut:
    """Return one product by id."""
    row = await pool.fetchrow(f"SELECT {COLUMNS} FROM products WHERE id = $1", product_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Product not found")
    return ProductOut(**dict(row))


@router.post(
    "",
    response_model=ProductOut,
    status_code=status.HTTP_201_CREATED,
    responses={401: {"model": Message}},
)
async def create_product(
    body: ProductIn,
    _: int = Depends(current_user_id),
    pool: asyncpg.Pool = Depends(get_pool),
) -> ProductOut:
    """Create a product; requires authentication."""
    row = await pool.fetchrow(
        "INSERT INTO products (name, description, price_cents, stock) "
        f"VALUES ($1, $2, $3, $4) RETURNING {COLUMNS}",
        body.name,
        body.description,
        body.price_cents,
        body.stock,
    )
    return ProductOut(**dict(row))


@router.patch(
    "/{product_id}",
    response_model=ProductOut,
    responses={401: {"model": Message}, 404: {"model": Message}},
)
async def update_product(
    product_id: int,
    body: ProductUpdate,
    _: int = Depends(current_user_id),
    pool: asyncpg.Pool = Depends(get_pool),
) -> ProductOut:
    """Update the supplied fields of a product; requires authentication."""
    row = await pool.fetchrow(
        "UPDATE products SET "
        "name = COALESCE($2, name), "
        "description = COALESCE($3, description), "
        "price_cents = COALESCE($4, price_cents), "
        "stock = COALESCE($5, stock) "
        f"WHERE id = $1 RETURNING {COLUMNS}",
        product_id,
        body.name,
        body.description,
        body.price_cents,
        body.stock,
    )
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Product not found")
    return ProductOut(**dict(row))


@router.delete(
    "/{product_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    responses={
        401: {"model": Message},
        404: {"model": Message},
        409: {"model": Message},
    },
)
async def delete_product(
    product_id: int,
    _: int = Depends(current_user_id),
    pool: asyncpg.Pool = Depends(get_pool),
) -> Response:
    """Delete a product that no order references; requires authentication."""
    try:
        deleted = await pool.fetchval(
            "DELETE FROM products WHERE id = $1 RETURNING id", product_id
        )
    except asyncpg.ForeignKeyViolationError as exc:
        raise HTTPException(
            status.HTTP_409_CONFLICT, "Product has orders and cannot be deleted"
        ) from exc
    if deleted is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Product not found")
    return Response(status_code=status.HTTP_204_NO_CONTENT)
EOF

# ── app/routers/orders.py ────────────────────────────────────────
cat > "${LESSON_DIR}/app/routers/orders.py" << 'EOF'
"""Order routes: create, get, list for the current user, update status, cancel."""
import asyncpg
from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.db import get_pool
from app.schemas import Message, OrderIn, OrderOut, OrderStatusUpdate
from app.security import current_user_id

router = APIRouter(prefix="/orders", tags=["orders"])

COLUMNS = "id, user_id, product_id, quantity, total_cents, status, created_at"


@router.post(
    "",
    response_model=OrderOut,
    status_code=status.HTTP_201_CREATED,
    responses={
        401: {"model": Message},
        404: {"model": Message},
        409: {"model": Message},
    },
)
async def create_order(
    body: OrderIn,
    user_id: int = Depends(current_user_id),
    pool: asyncpg.Pool = Depends(get_pool),
) -> OrderOut:
    """Place an order and decrement stock inside one transaction."""
    async with pool.acquire() as conn:
        async with conn.transaction():
            product = await conn.fetchrow(
                "SELECT price_cents, stock FROM products WHERE id = $1 FOR UPDATE",
                body.product_id,
            )
            if product is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Product not found")
            if product["stock"] < body.quantity:
                raise HTTPException(status.HTTP_409_CONFLICT, "Insufficient stock")
            await conn.execute(
                "UPDATE products SET stock = stock - $2 WHERE id = $1",
                body.product_id,
                body.quantity,
            )
            row = await conn.fetchrow(
                "INSERT INTO orders (user_id, product_id, quantity, total_cents) "
                f"VALUES ($1, $2, $3, $4) RETURNING {COLUMNS}",
                user_id,
                body.product_id,
                body.quantity,
                product["price_cents"] * body.quantity,
            )
    return OrderOut(**dict(row))


@router.get("", response_model=list[OrderOut], responses={401: {"model": Message}})
async def list_orders(
    limit: int = Query(default=20, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
    user_id: int = Depends(current_user_id),
    pool: asyncpg.Pool = Depends(get_pool),
) -> list[OrderOut]:
    """Return the authenticated user's orders, newest first."""
    rows = await pool.fetch(
        f"SELECT {COLUMNS} FROM orders WHERE user_id = $1 "
        "ORDER BY id DESC LIMIT $2 OFFSET $3",
        user_id,
        limit,
        offset,
    )
    return [OrderOut(**dict(row)) for row in rows]


@router.get(
    "/{order_id}",
    response_model=OrderOut,
    responses={401: {"model": Message}, 404: {"model": Message}},
)
async def get_order(
    order_id: int,
    user_id: int = Depends(current_user_id),
    pool: asyncpg.Pool = Depends(get_pool),
) -> OrderOut:
    """Return one order if it belongs to the authenticated user."""
    row = await pool.fetchrow(
        f"SELECT {COLUMNS} FROM orders WHERE id = $1 AND user_id = $2", order_id, user_id
    )
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Order not found")
    return OrderOut(**dict(row))


@router.patch(
    "/{order_id}/status",
    response_model=OrderOut,
    responses={
        401: {"model": Message},
        404: {"model": Message},
        409: {"model": Message},
    },
)
async def update_order_status(
    order_id: int,
    body: OrderStatusUpdate,
    user_id: int = Depends(current_user_id),
    pool: asyncpg.Pool = Depends(get_pool),
) -> OrderOut:
    """Move an order to a new status unless it is already cancelled."""
    row = await pool.fetchrow(
        "UPDATE orders SET status = $3 "
        "WHERE id = $1 AND user_id = $2 AND status <> 'cancelled' "
        f"RETURNING {COLUMNS}",
        order_id,
        user_id,
        body.status,
    )
    if row is not None:
        return OrderOut(**dict(row))
    exists = await pool.fetchval(
        "SELECT 1 FROM orders WHERE id = $1 AND user_id = $2", order_id, user_id
    )
    if exists is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Order not found")
    raise HTTPException(status.HTTP_409_CONFLICT, "Cancelled orders cannot change status")


@router.delete(
    "/{order_id}",
    response_model=OrderOut,
    responses={
        401: {"model": Message},
        404: {"model": Message},
        409: {"model": Message},
    },
)
async def cancel_order(
    order_id: int,
    user_id: int = Depends(current_user_id),
    pool: asyncpg.Pool = Depends(get_pool),
) -> OrderOut:
    """Cancel an order and return its quantity to stock."""
    async with pool.acquire() as conn:
        async with conn.transaction():
            order = await conn.fetchrow(
                "SELECT product_id, quantity, status FROM orders "
                "WHERE id = $1 AND user_id = $2 FOR UPDATE",
                order_id,
                user_id,
            )
            if order is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Order not found")
            if order["status"] == "cancelled":
                raise HTTPException(status.HTTP_409_CONFLICT, "Order already cancelled")
            await conn.execute(
                "UPDATE products SET stock = stock + $2 WHERE id = $1",
                order["product_id"],
                order["quantity"],
            )
            row = await conn.fetchrow(
                f"UPDATE orders SET status = 'cancelled' WHERE id = $1 RETURNING {COLUMNS}",
                order_id,
            )
    return OrderOut(**dict(row))
EOF

# ── app/main.py ──────────────────────────────────────────────────
cat > "${LESSON_DIR}/app/main.py" << 'EOF'
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
EOF

# ── tests/test_smoke.py ──────────────────────────────────────────
cat > "${LESSON_DIR}/tests/__init__.py" << 'EOF'
"""Smoke tests for the Lesson 2 backend."""
EOF

cat > "${LESSON_DIR}/tests/test_smoke.py" << 'EOF'
"""Smoke tests that run against the live API inside the api container."""
import os
import uuid
from collections.abc import Iterator

import httpx
import pytest

BASE_URL = os.getenv("QATP_BASE_URL", "http://localhost:8000")
EXPECTED_OPERATIONS = 17


@pytest.fixture(scope="session")
def client() -> Iterator[httpx.Client]:
    """Yield one HTTP client for the whole session."""
    with httpx.Client(base_url=BASE_URL, timeout=10) as http:
        yield http


def register(client: httpx.Client) -> dict[str, str]:
    """Register a unique user and return the token pair."""
    email = f"user-{uuid.uuid4().hex[:12]}@example.org"
    response = client.post("/auth/register", json={"email": email, "password": "hunter2"})
    assert response.status_code == 201, response.text
    return response.json()


@pytest.fixture()
def auth_headers(client: httpx.Client) -> dict[str, str]:
    """Return an Authorization header for a freshly registered user."""
    tokens = register(client)
    return {"Authorization": f"Bearer {tokens['access_token']}"}


def test_health_reports_both_dependencies(client: httpx.Client) -> None:
    """Health returns 200 with db and redis both connected."""
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok", "db": "connected", "redis": "connected"}


def test_spec_has_seventeen_operations(client: httpx.Client) -> None:
    """The OpenAPI spec lists exactly the operations the course builds on."""
    paths = client.get("/openapi.json").json()["paths"]
    assert sum(len(methods) for methods in paths.values()) == EXPECTED_OPERATIONS


def test_operation_ids_are_function_names(client: httpx.Client) -> None:
    """Operation ids are stable function names, not path-derived strings."""
    paths = client.get("/openapi.json").json()["paths"]
    assert paths["/orders"]["post"]["operationId"] == "create_order"
    assert paths["/health"]["get"]["operationId"] == "health"


def test_register_returns_jwt_and_duplicate_conflicts(client: httpx.Client) -> None:
    """Register issues a three-part JWT and rejects the same email with 409."""
    email = f"dup-{uuid.uuid4().hex[:12]}@example.org"
    body = {"email": email, "password": "hunter2"}
    first = client.post("/auth/register", json=body)
    assert first.status_code == 201
    assert first.json()["access_token"].count(".") == 2
    assert client.post("/auth/register", json=body).status_code == 409


def test_search_is_not_swallowed_by_id_route(client: httpx.Client) -> None:
    """/products/search resolves to the search route, not /products/{id}."""
    response = client.get("/products/search", params={"q": "keyboard"})
    assert response.status_code == 200
    assert any("Keyboard" in item["name"] for item in response.json())


def test_order_decrements_stock(client: httpx.Client, auth_headers: dict[str, str]) -> None:
    """Creating an order lowers stock and the order is readable by its owner."""
    created = client.post(
        "/products",
        json={"name": "Stock Probe", "description": "", "price_cents": 250, "stock": 5},
        headers=auth_headers,
    ).json()
    order = client.post(
        "/orders", json={"product_id": created["id"], "quantity": 2}, headers=auth_headers
    )
    assert order.status_code == 201
    assert order.json()["total_cents"] == 500
    assert client.get(f"/products/{created['id']}").json()["stock"] == 3
    fetched = client.get(f"/orders/{order.json()['id']}", headers=auth_headers)
    assert fetched.status_code == 200


def test_refresh_token_is_single_use(client: httpx.Client) -> None:
    """A refresh token works once and is rejected on replay."""
    tokens = register(client)
    body = {"refresh_token": tokens["refresh_token"]}
    assert client.post("/auth/refresh", json=body).status_code == 200
    assert client.post("/auth/refresh", json=body).status_code == 401


def test_logout_revokes_access_token(client: httpx.Client, auth_headers: dict[str, str]) -> None:
    """After logout the same access token is rejected with 401."""
    assert client.get("/auth/me", headers=auth_headers).status_code == 200
    assert client.post("/auth/logout", headers=auth_headers).status_code == 200
    assert client.get("/auth/me", headers=auth_headers).status_code == 401
EOF

# ── Makefile ─────────────────────────────────────────────────────
cat > "${LESSON_DIR}/Makefile" << 'EOF'
# Recipes use ">" instead of a tab so copy-paste never breaks them
.RECIPEPREFIX := >
.PHONY: up down logs health test spec clean

up:
> docker compose up -d --build --wait

down:
> docker compose down

logs:
> docker compose logs -f api

health:
> curl -s localhost:8000/health | python3 -m json.tool

test:
> docker compose exec -T api pytest tests -v

spec:
> curl -s localhost:8000/openapi.json -o reports/openapi.json
> @echo "Wrote reports/openapi.json"

clean:
> docker compose down -v
> rm -f reports/*.json reports/*.txt
EOF

# ── README.md ────────────────────────────────────────────────────
cat > "${LESSON_DIR}/README.md" << 'EOF'
# Lesson 02 — QATP-App: The Backend

FastAPI backend for the application under test. Seventeen operations, each
with a declared response model and declared error responses.

| Group      | Operations                                         |
|------------|----------------------------------------------------|
| /auth      | register, login, refresh, logout, me               |
| /products  | list, search, get, create, update, delete          |
| /orders    | create, get, list, update status, cancel           |
| /health    | checks Postgres and Redis, 503 if either is down   |

## Run

    make up        # build and start db, redis, api; waits for healthy
    make health    # {"status":"ok","db":"connected","redis":"connected"}
    make test      # 8 passed
    make spec      # writes reports/openapi.json
    make clean     # stop and delete volumes

Swagger UI: http://localhost:8000/docs
EOF

echo -e "${GREEN}✓${RESET} Wrote application, tests, Makefile, and README"

# ── run_test: exercise the primary deliverable ───────────────────
run_test() {
  echo -e "\n${BOLD}${CYAN}▶ run_test: building and exercising the backend${RESET}"
  if ! "${COMPOSE[@]}" up -d --build; then
    echo -e "❌ FAILED — docker compose could not start the stack"
    return 1
  fi

  local healthy=0
  for _ in $(seq 1 60); do
    if curl -fsS localhost:8000/health -o "${LESSON_DIR}/reports/health.json" 2>/dev/null; then
      healthy=1
      break
    fi
    sleep 2
  done
  if [[ "${healthy}" -ne 1 ]]; then
    echo -e "❌ FAILED — /health did not return 200 within 120 seconds"
    return 1
  fi

  curl -fsS localhost:8000/openapi.json -o "${LESSON_DIR}/reports/openapi.json"

  "${COMPOSE[@]}" exec -T api python -c \
    "import json, urllib.request as u; s = json.load(u.urlopen('http://localhost:8000/openapi.json')); print(sum(len(m) for m in s['paths'].values()))" \
    > "${LESSON_DIR}/reports/endpoint_count.txt"

  curl -sS -X POST localhost:8000/auth/register \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"smoke-$(date +%s)@example.org\",\"password\":\"hunter2\"}" \
    -o "${LESSON_DIR}/reports/register.json"

  if "${COMPOSE[@]}" exec -T api pytest tests -q > "${LESSON_DIR}/reports/pytest.txt" 2>&1; then
    echo -e "${GREEN}✅ PASSED${RESET} — stack is up and smoke tests are green"
    return 0
  fi
  tail -n 20 "${LESSON_DIR}/reports/pytest.txt"
  echo -e "❌ FAILED — smoke tests failed; see ${LESSON_DIR}/reports/pytest.txt"
  return 1
}

# ── verify_result: check what run_test left on disk ──────────────
verify_result() {
  local failures=0
  local reports="${LESSON_DIR}/reports"

  if grep -q '"db":"connected"' "${reports}/health.json" 2>/dev/null \
     && grep -q '"redis":"connected"' "${reports}/health.json" 2>/dev/null; then
    echo -e "  ${GREEN}✓${RESET} health.json shows db and redis connected"
  else
    echo -e "  ${YELLOW}✗${RESET} health.json missing or a dependency is unreachable"
    failures=$((failures + 1))
  fi

  if [[ "$(tr -d '[:space:]' < "${reports}/endpoint_count.txt" 2>/dev/null)" == "17" ]]; then
    echo -e "  ${GREEN}✓${RESET} openapi.json lists 17 operations"
  else
    echo -e "  ${YELLOW}✗${RESET} endpoint_count.txt is not 17"
    failures=$((failures + 1))
  fi

  if grep -q '"access_token"' "${reports}/register.json" 2>/dev/null; then
    echo -e "  ${GREEN}✓${RESET} register.json contains an access_token"
  else
    echo -e "  ${YELLOW}✗${RESET} register.json has no access_token"
    failures=$((failures + 1))
  fi

  if grep -Eq '[0-9]+ passed' "${reports}/pytest.txt" 2>/dev/null \
     && ! grep -Eq '[0-9]+ (failed|error)' "${reports}/pytest.txt"; then
    echo -e "  ${GREEN}✓${RESET} pytest.txt reports all tests passed"
  else
    echo -e "  ${YELLOW}✗${RESET} pytest.txt reports failures or is missing"
    failures=$((failures + 1))
  fi

  if [[ "${failures}" -eq 0 ]]; then
    echo -e "${BOLD}${GREEN}VERDICT: Lesson 02 backend verified — 4/4 checks passed${RESET}"
    return 0
  fi
  echo -e "${BOLD}${YELLOW}VERDICT: Lesson 02 incomplete — ${failures} check(s) failed${RESET}"
  return 1
}

# ── Execute ──────────────────────────────────────────────────────
if [[ "${1:-}" == "--no-run" ]]; then
  echo -e "${YELLOW}Skipped run_test (--no-run). Files are in ${LESSON_DIR}/.${RESET}"
elif ! command -v docker > /dev/null 2>&1; then
  echo -e "${YELLOW}Docker not found on PATH. Files are written; install Docker, then rerun.${RESET}"
else
  if run_test; then
    verify_result || true
  else
    echo -e "${YELLOW}run_test failed. Inspect: docker compose -f ${LESSON_DIR}/docker-compose.yml logs api${RESET}"
  fi
fi

# ── Next steps ───────────────────────────────────────────────────
echo -e "\n${BOLD}${CYAN}NEXT STEPS${RESET}"
echo -e "${BOLD}1.${RESET} Check health from the terminal:"
echo -e "     ${CYAN}curl -s localhost:8000/health | python3 -m json.tool${RESET}"
echo -e "     Expected: \"db\": \"connected\" and \"redis\": \"connected\""
echo -e "${BOLD}2.${RESET} Open Swagger UI in a browser:"
echo -e "     ${CYAN}http://localhost:8000/docs${RESET}"
echo -e "     Expected: 17 operations under auth, products, orders, ops"
echo -e "${BOLD}3.${RESET} Register a user:"
echo -e "     ${CYAN}curl -X POST localhost:8000/auth/register -H \"Content-Type: application/json\" -d '{\"email\":\"test@test.com\",\"password\":\"hunter2\"}'${RESET}"
echo -e "     Expected: {\"access_token\":\"eyJ...\",\"refresh_token\":\"eyJ...\",\"token_type\":\"bearer\"}"
echo -e "     Second run: {\"detail\":\"Email already registered\"}"
echo -e "${BOLD}4.${RESET} Run the smoke tests:"
echo -e "     ${CYAN}cd ${LESSON_DIR} && make test${RESET}"
echo -e "     Expected: 8 passed"
echo -e "${BOLD}5.${RESET} Stop the stack when finished:"
echo -e "     ${CYAN}cd ${LESSON_DIR} && make down${RESET}"
echo -e "     Expected: containers removed, data volume kept"