"""Health endpoint tests that run against real Postgres and Redis."""
from __future__ import annotations

from collections.abc import AsyncIterator

import httpx
import pytest

from app.main import app


@pytest.fixture
async def client() -> AsyncIterator[httpx.AsyncClient]:
    """Yield an in-process HTTP client bound to the FastAPI app."""
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://qatp") as http:
        yield http


async def test_health_returns_200(client: httpx.AsyncClient) -> None:
    """Return 200 when both backing services answer."""
    response = await client.get("/health")
    assert response.status_code == 200


async def test_health_reports_db_connected(client: httpx.AsyncClient) -> None:
    """Report Postgres as connected in the JSON body."""
    body = (await client.get("/health")).json()
    assert body["db"] == "connected"


async def test_health_reports_redis_connected(client: httpx.AsyncClient) -> None:
    """Report Redis as connected in the JSON body."""
    body = (await client.get("/health")).json()
    assert body["redis"] == "connected"


async def test_health_returns_503_when_db_down(
    client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Return 503 and db=unreachable when Postgres refuses connections."""
    monkeypatch.setattr("app.main.DATABASE_URL", "postgresql://qatp:qatp@localhost:1/qatp")
    response = await client.get("/health")
    assert response.status_code == 503
    assert response.json()["db"] == "unreachable"
