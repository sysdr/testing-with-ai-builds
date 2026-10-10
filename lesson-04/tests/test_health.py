"""
test_health.py — QATP-App /health endpoint tests.

Asserts that both the database and Redis cache report as connected.
The /health endpoint is the canary for the entire docker-compose stack.
"""
from __future__ import annotations

import pytest
from httpx import AsyncClient


@pytest.mark.health
async def test_health_returns_connected_services(http_client: AsyncClient) -> None:
    """GET /health must return 200 with db and redis both reporting 'connected'.

    If this test fails, the docker-compose stack is not healthy and no
    other test should be trusted. Fix the infrastructure before debugging
    application tests.
    """
    response = await http_client.get("/health")

    assert response.status_code == 200, (
        f"Expected 200 from /health, got {response.status_code}: {response.text}"
    )

    body: dict[str, str] = response.json()

    assert "db" in body, f"/health response missing 'db' key: {body}"
    assert "redis" in body, f"/health response missing 'redis' key: {body}"

    assert body["db"] == "connected", (
        f"Database not connected. /health returned: {body}"
    )
    assert body["redis"] == "connected", (
        f"Redis not connected. /health returned: {body}"
    )
