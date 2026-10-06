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
