"""
test_auth.py — QATP-App /auth endpoint tests.

Covers registration, login, and JWT issuance. Each test registers a
fresh user with a UUID-suffixed email to prevent inter-test conflicts.
"""
from __future__ import annotations

import uuid

import pytest
from httpx import AsyncClient


@pytest.mark.auth
async def test_register_and_login_returns_jwt(http_client: AsyncClient) -> None:
    """Register a new user and verify a JWT access_token is returned on login.

    Verifiable output: response contains 'access_token' with length > 20
    (a minimal sanity check that the value is a real JWT, not an empty string).
    """
    email: str = f"auth-test-{uuid.uuid4().hex[:8]}@qatp.test"
    password: str = "SecurePass99!"

    reg = await http_client.post(
        "/auth/register",
        json={"email": email, "password": password},
    )
    assert reg.status_code == 201, (
        f"Registration failed ({reg.status_code}): {reg.text}"
    )

    login = await http_client.post(
        "/auth/login",
        json={"email": email, "password": password},
    )
    assert login.status_code == 200, (
        f"Login failed ({login.status_code}): {login.text}"
    )

    data: dict[str, object] = login.json()
    assert "access_token" in data, f"No access_token in login response: {data}"
    assert isinstance(data["access_token"], str)
    assert len(data["access_token"]) > 20, (
        f"access_token suspiciously short: {data['access_token']!r}"
    )


@pytest.mark.auth
async def test_login_with_wrong_password_returns_401(
    http_client: AsyncClient,
) -> None:
    """Login with the correct email but wrong password must return 401."""
    email: str = f"wrongpass-{uuid.uuid4().hex[:8]}@qatp.test"
    password: str = "CorrectPass99!"

    await http_client.post(
        "/auth/register",
        json={"email": email, "password": password},
    )

    bad_login = await http_client.post(
        "/auth/login",
        json={"email": email, "password": "WrongPassword!"},
    )
    assert bad_login.status_code == 401, (
        f"Expected 401 for wrong password, got {bad_login.status_code}"
    )
