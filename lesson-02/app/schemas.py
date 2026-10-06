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
