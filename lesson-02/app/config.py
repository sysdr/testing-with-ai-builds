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
