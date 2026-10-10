"""
conftest.py — QATP-App shared pytest fixtures.

Designed to scale across 90 days of tests without modification.
All fixtures are session-scoped: one HTTP client, one login per run.
"""
from __future__ import annotations

import os
import uuid
from typing import AsyncGenerator

import httpx
import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport


BASE_URL_DEFAULT: str = "http://localhost:8000"


@pytest.fixture(scope="session")
def base_url() -> str:
    """Return the QATP-App base URL.

    Reads BASE_URL from the environment so CI overrides work without
    touching any test file. Falls back to localhost:8000 for local runs.

    Example override:
        BASE_URL=http://qatp-staging:8000 pytest tests/
    """
    return os.environ.get("BASE_URL", BASE_URL_DEFAULT)


@pytest_asyncio.fixture(scope="session")
async def http_client(base_url: str) -> AsyncGenerator[AsyncClient, None]:
    """Live-server variant: AsyncClient connected to a running QATP-App.

    Requires docker-compose to be running. Use this fixture for
    integration tests that need a real database and Redis connection.

    Depends on: base_url
    """
    async with AsyncClient(base_url=base_url, timeout=10.0) as client:
        yield client


@pytest_asyncio.fixture(scope="session")
async def http_client_asgi() -> AsyncGenerator[AsyncClient, None]:
    """In-process variant: mounts the FastAPI app via ASGITransport.

    No network socket is opened. Eliminates port-conflict flakiness
    entirely. This is the approach used by Stripe for their internal
    FastAPI tooling test suites.

    Use this fixture for tests that do not require real external services
    (Redis, Postgres) — i.e., when the app is the unit under test.

    Depends on: nothing (app is imported directly)
    """
    from app.main import app  # local import keeps fixture optional

    transport = ASGITransport(app=app)
    async with AsyncClient(
        transport=transport,
        base_url="http://test",
        timeout=10.0,
    ) as client:
        yield client


@pytest_asyncio.fixture(scope="session")
async def auth_headers(http_client: AsyncClient) -> dict[str, str]:
    """Register a unique user, log in, and return Authorization headers.

    Session-scoped: executes exactly once per pytest invocation regardless
    of how many tests request this fixture. One network login for the
    entire suite.

    The UUID suffix in the email prevents conflicts across parallel runs
    and across test sessions that share the same database.

    Depends on: http_client
    """
    email: str = f"testuser-{uuid.uuid4().hex[:8]}@qatp.test"
    password: str = "TestPass123!"

    register_response = await http_client.post(
        "/auth/register",
        json={"email": email, "password": password},
    )
    assert register_response.status_code == 201, (
        f"Registration failed ({register_response.status_code}): "
        f"{register_response.text}"
    )

    login_response = await http_client.post(
        "/auth/login",
        json={"email": email, "password": password},
    )
    assert login_response.status_code == 200, (
        f"Login failed ({login_response.status_code}): "
        f"{login_response.text}"
    )

    token: str = login_response.json()["access_token"]
    return {"Authorization": f"Bearer {token}"}
