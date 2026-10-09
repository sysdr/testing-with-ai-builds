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
