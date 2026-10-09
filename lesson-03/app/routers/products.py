"""Product routes: list, search, get, create, update, delete."""
import logging

import asyncpg
from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response, status

from app.db import get_pool
from app.schemas import Message, ProductIn, ProductOut, ProductUpdate
from app.security import current_user_id

router = APIRouter(prefix="/products", tags=["products"])
log = logging.getLogger("qatp.ai")

COLUMNS = "id, name, description, price_cents, stock"


async def _sync_product_index(request: Request, pool: asyncpg.Pool) -> None:
    """Rebuild the Chroma index so /ai/status.indexed stays equal to the catalogue size."""
    chat = getattr(request.app.state, "chat", None)
    if chat is None:
        return
    try:
        await chat.reindex(pool)
    except Exception as exc:
        # Product CRUD must still succeed when Ollama/Chroma are down; /ai/reindex retries later
        log.warning("event=ai.reindex_after_product_write_skipped reason=%s", exc)


@router.get("", response_model=list[ProductOut])
async def list_products(
    limit: int = Query(default=20, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
    pool: asyncpg.Pool = Depends(get_pool),
) -> list[ProductOut]:
    """Return one page of products ordered by id."""
    rows = await pool.fetch(
        f"SELECT {COLUMNS} FROM products ORDER BY id LIMIT $1 OFFSET $2", limit, offset
    )
    return [ProductOut(**dict(row)) for row in rows]


# Declared before /{product_id}: FastAPI matches routes in declaration order,
# and "search" would otherwise be parsed as an integer id and rejected with 422.
@router.get("/search", response_model=list[ProductOut])
async def search_products(
    q: str = Query(min_length=1, max_length=100),
    pool: asyncpg.Pool = Depends(get_pool),
) -> list[ProductOut]:
    """Return products whose name or description contains the query."""
    rows = await pool.fetch(
        f"SELECT {COLUMNS} FROM products "
        "WHERE name ILIKE $1 OR description ILIKE $1 ORDER BY id LIMIT 50",
        f"%{q}%",
    )
    return [ProductOut(**dict(row)) for row in rows]


@router.get("/{product_id}", response_model=ProductOut, responses={404: {"model": Message}})
async def get_product(
    product_id: int, pool: asyncpg.Pool = Depends(get_pool)
) -> ProductOut:
    """Return one product by id."""
    row = await pool.fetchrow(f"SELECT {COLUMNS} FROM products WHERE id = $1", product_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Product not found")
    return ProductOut(**dict(row))


@router.post(
    "",
    response_model=ProductOut,
    status_code=status.HTTP_201_CREATED,
    responses={401: {"model": Message}},
)
async def create_product(
    request: Request,
    body: ProductIn,
    _: int = Depends(current_user_id),
    pool: asyncpg.Pool = Depends(get_pool),
) -> ProductOut:
    """Create a product; requires authentication."""
    row = await pool.fetchrow(
        "INSERT INTO products (name, description, price_cents, stock) "
        f"VALUES ($1, $2, $3, $4) RETURNING {COLUMNS}",
        body.name,
        body.description,
        body.price_cents,
        body.stock,
    )
    await _sync_product_index(request, pool)
    return ProductOut(**dict(row))


@router.patch(
    "/{product_id}",
    response_model=ProductOut,
    responses={401: {"model": Message}, 404: {"model": Message}},
)
async def update_product(
    request: Request,
    product_id: int,
    body: ProductUpdate,
    _: int = Depends(current_user_id),
    pool: asyncpg.Pool = Depends(get_pool),
) -> ProductOut:
    """Update the supplied fields of a product; requires authentication."""
    row = await pool.fetchrow(
        "UPDATE products SET "
        "name = COALESCE($2, name), "
        "description = COALESCE($3, description), "
        "price_cents = COALESCE($4, price_cents), "
        "stock = COALESCE($5, stock) "
        f"WHERE id = $1 RETURNING {COLUMNS}",
        product_id,
        body.name,
        body.description,
        body.price_cents,
        body.stock,
    )
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Product not found")
    await _sync_product_index(request, pool)
    return ProductOut(**dict(row))


@router.delete(
    "/{product_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    responses={
        401: {"model": Message},
        404: {"model": Message},
        409: {"model": Message},
    },
)
async def delete_product(
    request: Request,
    product_id: int,
    _: int = Depends(current_user_id),
    pool: asyncpg.Pool = Depends(get_pool),
) -> Response:
    """Delete a product that no order references; requires authentication."""
    try:
        deleted = await pool.fetchval(
            "DELETE FROM products WHERE id = $1 RETURNING id", product_id
        )
    except asyncpg.ForeignKeyViolationError as exc:
        raise HTTPException(
            status.HTTP_409_CONFLICT, "Product has orders and cannot be deleted"
        ) from exc
    if deleted is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Product not found")
    await _sync_product_index(request, pool)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
