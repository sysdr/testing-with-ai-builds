"""Smoke tests that run against the live API inside the api container."""
import os
import uuid
from collections.abc import Iterator

import httpx
import pytest

BASE_URL = os.getenv("QATP_BASE_URL", "http://localhost:8000")
EXPECTED_OPERATIONS = 20


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
