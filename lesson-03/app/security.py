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
