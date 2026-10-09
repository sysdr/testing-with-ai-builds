#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

PREV_DIR="lesson-02"
LESSON_DIR="lesson-03"
COMPOSE=(docker compose -f "${LESSON_DIR}/docker-compose.yml")

echo -e "${BOLD}${CYAN}════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Module 0 — Build Before You Test${RESET}"
echo -e "${BOLD}  Lesson 3 — QATP-App: The AI Layer${RESET}"
echo -e "${BOLD}  Day 3 of 90${RESET}"
echo -e "${BOLD}${CYAN}════════════════════════════════════════════════${RESET}"

# ── Start from the Lesson 2 backend ──────────────────────────────
if [[ ! -f "${PREV_DIR}/app/main.py" ]]; then
  echo -e "${YELLOW}${PREV_DIR}/ not found. Run: bash setup_lesson_02.sh --no-run   then rerun this script.${RESET}"
  exit 1
fi
mkdir -p "${LESSON_DIR}"
cp -R "${PREV_DIR}/app" "${PREV_DIR}/tests" "${PREV_DIR}/Dockerfile" "${LESSON_DIR}/"
mkdir -p "${LESSON_DIR}/app/ai" "${LESSON_DIR}/reports"
# Lesson 3 adds three operations (/chat, /ai/reindex, /ai/status), so the Lesson 2 count moves from 17 to 20
sed -i.bak 's/^EXPECTED_OPERATIONS = 17$/EXPECTED_OPERATIONS = 20/' "${LESSON_DIR}/tests/test_smoke.py"
rm -f "${LESSON_DIR}/tests/test_smoke.py.bak"
echo -e "${GREEN}✓${RESET} Copied the Lesson 2 backend into ${LESSON_DIR}/"

# ── requirements.txt ─────────────────────────────────────────────
cat > "${LESSON_DIR}/requirements.txt" << 'EOF'
fastapi==0.115.0
uvicorn[standard]==0.30.6
asyncpg==0.29.0
redis==5.0.8
python-jose[cryptography]==3.3.0
bcrypt==4.2.0
httpx==0.27.2
# Thin HTTP client only; must match the chromadb/chroma server tag in docker-compose.yml
chromadb-client==0.5.23
pytest==8.3.3
EOF

# ── docker-compose.yml ───────────────────────────────────────────
cat > "${LESSON_DIR}/docker-compose.yml" << 'EOF'
name: qatp-lesson-03

services:
  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: qatp
      POSTGRES_PASSWORD: qatp
      POSTGRES_DB: qatp
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U qatp -d qatp"]
      interval: 2s
      timeout: 3s
      retries: 30

  redis:
    image: redis:7-alpine
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 2s
      timeout: 3s
      retries: 30

  # Host Ollama (Windows) — skip the in-compose ollama/ollama-pull services
  # Reachable from containers as LAPTOP-RVRF49B4 / 192.168.1.13:11434

  chroma:
    image: chromadb/chroma:0.5.23
    ports:
      # Host 8001 because the API already owns 8000
      - "8001:8000"
    environment:
      IS_PERSISTENT: "TRUE"
      ANONYMIZED_TELEMETRY: "FALSE"
    volumes:
      - chroma-data:/chroma/chroma

  api:
    build: .
    ports:
      - "8000:8000"
    environment:
      DATABASE_URL: postgresql://qatp:qatp@db:5432/qatp
      REDIS_URL: redis://redis:6379/0
      JWT_SECRET: dev-only-change-me
      # LAN IP of LAPTOP-RVRF49B4 — Docker's embedded DNS cannot resolve that Windows hostname
      OLLAMA_URL: http://192.168.1.13:11434
      CHAT_MODEL: llama3.2:3b
      EMBED_MODEL: nomic-embed-text
      CHROMA_HOST: chroma
      CHROMA_PORT: "8000"
      # Ollama unloads an idle model after 5 minutes by default; the next request then pays the load time
      OLLAMA_KEEP_ALIVE: 30m
    volumes:
      # The chat log is written here so you can read it from the host
      - ./reports:/app/reports
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
      chroma:
        condition: service_started
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"]
      interval: 3s
      timeout: 3s
      retries: 20

volumes:
  chroma-data:
EOF

# ── app/config.py ────────────────────────────────────────────────
cat > "${LESSON_DIR}/app/config.py" << 'EOF'
"""Runtime settings read once from environment variables."""
import os
from dataclasses import dataclass, field
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    """Immutable configuration for the API process."""

    database_url: str = os.getenv("DATABASE_URL", "postgresql://qatp:qatp@db:5432/qatp")
    redis_url: str = os.getenv("REDIS_URL", "redis://redis:6379/0")
    jwt_secret: str = os.getenv("JWT_SECRET", "dev-only-change-me")
    access_ttl: int = int(os.getenv("ACCESS_TTL_SECONDS", "900"))
    refresh_ttl: int = int(os.getenv("REFRESH_TTL_SECONDS", "604800"))
    ollama_url: str = os.getenv("OLLAMA_URL", "http://ollama:11434")
    chat_model: str = os.getenv("CHAT_MODEL", "llama3.2:3b")
    embed_model: str = os.getenv("EMBED_MODEL", "nomic-embed-text")
    ollama_keep_alive: str = os.getenv("OLLAMA_KEEP_ALIVE", "30m")
    llm_timeout_seconds: float = float(os.getenv("LLM_TIMEOUT_SECONDS", "120"))
    max_answer_tokens: int = int(os.getenv("MAX_ANSWER_TOKENS", "200"))
    llm_seed: int = int(os.getenv("LLM_SEED", "42"))
    chroma_host: str = os.getenv("CHROMA_HOST", "chroma")
    chroma_port: int = int(os.getenv("CHROMA_PORT", "8000"))
    chroma_collection: str = os.getenv("CHROMA_COLLECTION", "products")
    retrieval_k: int = int(os.getenv("RETRIEVAL_K", "3"))
    chat_log: Path = field(default_factory=lambda: Path(os.getenv("CHAT_LOG", "reports/chat_log.jsonl")))


settings = Settings()
EOF

# ── app/ai/__init__.py ───────────────────────────────────────────
cat > "${LESSON_DIR}/app/ai/__init__.py" << 'EOF'
"""The AI layer: Ollama for embeddings and answers, Chroma for retrieval."""
EOF

# ── app/ai/ollama.py ─────────────────────────────────────────────
cat > "${LESSON_DIR}/app/ai/ollama.py" << 'EOF'
"""A small async client for the three Ollama endpoints the app uses."""
from dataclasses import dataclass

import httpx


class OllamaError(RuntimeError):
    """Raised when Ollama is unreachable, slow, or missing a model."""


class OllamaTimeout(OllamaError):
    """Raised when Ollama does not finish within the configured timeout."""


@dataclass(frozen=True)
class Generation:
    """One completed answer and the metadata Ollama reports about it."""

    text: str
    model: str
    done_reason: str
    prompt_tokens: int
    completion_tokens: int


class OllamaClient:
    """Calls /api/tags, /api/embed and /api/generate on one Ollama server."""

    def __init__(self, base_url: str, timeout_seconds: float, keep_alive: str) -> None:
        """Create the HTTP client; no request is made until a method is called."""
        self._http = httpx.AsyncClient(base_url=base_url, timeout=timeout_seconds)
        self._keep_alive = keep_alive

    async def models(self) -> list[str]:
        """Return the names of the models already pulled onto the server."""
        try:
            response = await self._http.get("/api/tags", timeout=5)
            response.raise_for_status()
        except httpx.HTTPError as exc:
            raise OllamaError(f"cannot list models: {exc}") from exc
        return [model["name"] for model in response.json().get("models", [])]

    async def embed(self, model: str, texts: list[str]) -> list[list[float]]:
        """Return one embedding vector per input text."""
        payload = {"model": model, "input": texts, "keep_alive": self._keep_alive}
        body = await self._post("/api/embed", payload)
        embeddings = body.get("embeddings", [])
        if len(embeddings) != len(texts):
            raise OllamaError(f"asked for {len(texts)} embeddings, got {len(embeddings)}")
        return embeddings

    async def generate(self, model: str, prompt: str, seed: int, max_tokens: int) -> Generation:
        """Return a single non-streamed answer with temperature 0 and a fixed seed."""
        payload = {
            "model": model,
            "prompt": prompt,
            "stream": False,
            "keep_alive": self._keep_alive,
            "options": {"temperature": 0, "seed": seed, "num_predict": max_tokens},
        }
        body = await self._post("/api/generate", payload)
        return Generation(
            text=body.get("response", "").strip(),
            model=body.get("model", model),
            done_reason=body.get("done_reason", "unknown"),
            prompt_tokens=int(body.get("prompt_eval_count", 0)),
            completion_tokens=int(body.get("eval_count", 0)),
        )

    async def aclose(self) -> None:
        """Close the underlying connection pool."""
        await self._http.aclose()

    async def _post(self, path: str, payload: dict[str, object]) -> dict[str, object]:
        """POST JSON and translate transport failures into OllamaError."""
        try:
            response = await self._http.post(path, json=payload)
        except httpx.TimeoutException as exc:
            raise OllamaTimeout(f"{path} timed out") from exc
        except httpx.HTTPError as exc:
            raise OllamaError(f"{path} unreachable: {exc}") from exc
        if response.status_code == 404:
            raise OllamaError(f"{path}: model not found; run `make pull`")
        if response.status_code >= 400:
            raise OllamaError(f"{path} answered {response.status_code}: {response.text[:200]}")
        return response.json()
EOF

# ── app/ai/vectors.py ────────────────────────────────────────────
cat > "${LESSON_DIR}/app/ai/vectors.py" << 'EOF'
"""The product index in Chroma. Synchronous client; call it through asyncio.to_thread."""
from dataclasses import dataclass

import chromadb


@dataclass(frozen=True)
class Hit:
    """One retrieved product and how far it sits from the question."""

    product_id: int
    name: str
    distance: float
    document: str


class ProductIndex:
    """Stores one embedding per product and finds the nearest ones to a question."""

    def __init__(self, host: str, port: int, collection: str) -> None:
        """Remember where Chroma lives; connect lazily so startup never blocks on it."""
        self._host = host
        self._port = port
        self._name = collection
        self._client: chromadb.ClientAPI | None = None

    def heartbeat(self) -> bool:
        """Return True if Chroma answers."""
        try:
            self._connect().heartbeat()
        except Exception:
            self._client = None
            return False
        return True

    def count(self) -> int:
        """Return how many products are indexed."""
        return self._collection().count()

    def replace_all(self, ids: list[int], names: list[str], documents: list[str],
                    embeddings: list[list[float]]) -> int:
        """Drop the collection and index exactly the given products."""
        client = self._connect()
        try:
            client.delete_collection(self._name)
        except Exception:
            # Chroma raises if the collection does not exist yet; nothing to delete is fine
            client.get_or_create_collection(self._name)
        collection = self._collection()
        if ids:
            collection.add(
                ids=[str(product_id) for product_id in ids],
                embeddings=embeddings,
                documents=documents,
                metadatas=[{"product_id": product_id, "name": name} for product_id, name in zip(ids, names)],
            )
        return collection.count()

    def query(self, embedding: list[float], k: int) -> list[Hit]:
        """Return up to k nearest products, closest first. Never empty while the index has rows."""
        result = self._collection().query(query_embeddings=[embedding], n_results=k)
        hits: list[Hit] = []
        for metadata, distance, document in zip(result["metadatas"][0], result["distances"][0],
                                                result["documents"][0]):
            hits.append(Hit(int(metadata["product_id"]), str(metadata["name"]), float(distance), document))
        return hits

    def _collection(self) -> chromadb.Collection:
        """Return the product collection, creating it with cosine distance if needed."""
        return self._connect().get_or_create_collection(
            self._name, metadata={"hnsw:space": "cosine"}, embedding_function=None)

    def _connect(self) -> chromadb.ClientAPI:
        """Open the HTTP client on first use."""
        if self._client is None:
            self._client = chromadb.HttpClient(host=self._host, port=self._port)
        return self._client
EOF

# ── app/ai/prompts.py ────────────────────────────────────────────
cat > "${LESSON_DIR}/app/ai/prompts.py" << 'EOF'
"""Prompt text lives in one place and carries a version, so every answer can name the prompt that made it."""
from app.ai.vectors import Hit

PROMPT_VERSION = "shop-assistant-v1"

TEMPLATE = """You are the shop assistant for QATP Store.
Answer the customer's question using only the products listed below.
If none of them fits, say that the store does not sell it.
Mention prices in dollars. Keep the answer under 80 words.

Products:
{context}

Customer question: {question}
Answer:"""


def product_document(name: str, description: str, price_cents: int, stock: int) -> str:
    """Render one product as the text that gets embedded and shown to the model."""
    return f"{name}: {description}. Price ${price_cents / 100:.2f}. {stock} in stock."


def build_prompt(question: str, hits: list[Hit]) -> str:
    """Fill the template with the retrieved products and the question."""
    context = "\n".join(f"- [{hit.product_id}] {hit.document}" for hit in hits)
    return TEMPLATE.format(context=context or "- (no products indexed)", question=question.strip())
EOF

# ── app/ai/service.py ────────────────────────────────────────────
cat > "${LESSON_DIR}/app/ai/service.py" << 'EOF'
"""The /chat pipeline: embed, retrieve, prompt, generate, and record the evidence."""
import asyncio
import json
import logging
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import asyncpg

from app.ai.ollama import OllamaClient
from app.ai.prompts import PROMPT_VERSION, build_prompt, product_document
from app.ai.vectors import ProductIndex
from app.config import Settings
from app.schemas_ai import ChatOut, ChatSource, ChatTimings, ChatTokens

log = logging.getLogger("qatp.ai")


def elapsed_ms(started: float) -> float:
    """Milliseconds since a perf_counter reading, rounded to 0.1."""
    return round((time.perf_counter() - started) * 1000, 1)


class ChatService:
    """Answers product questions and returns the answer with everything needed to judge it."""

    def __init__(self, settings: Settings, ollama: OllamaClient, index: ProductIndex) -> None:
        """Keep references to the two AI dependencies and the settings."""
        self._settings = settings
        self._ollama = ollama
        self._index = index

    @property
    def index(self) -> ProductIndex:
        """The product index, for status checks."""
        return self._index

    @property
    def ollama(self) -> OllamaClient:
        """The Ollama client, for status checks."""
        return self._ollama

    async def reindex(self, pool: asyncpg.Pool) -> int:
        """Embed every product in Postgres and replace the Chroma collection with them."""
        rows = await pool.fetch("SELECT id, name, description, price_cents, stock FROM products ORDER BY id")
        documents = [product_document(r["name"], r["description"], r["price_cents"], r["stock"]) for r in rows]
        embeddings = await self._ollama.embed(self._settings.embed_model, documents) if documents else []
        count = await asyncio.to_thread(
            self._index.replace_all, [r["id"] for r in rows], [r["name"] for r in rows], documents, embeddings)
        log.info("event=ai.reindexed products=%d collection=%s", count, self._settings.chroma_collection)
        return count

    async def answer(self, question: str) -> ChatOut:
        """Run the full pipeline for one question and append it to the chat log."""
        request_id = uuid.uuid4().hex[:12]
        total_started = time.perf_counter()

        started = time.perf_counter()
        [vector] = await self._ollama.embed(self._settings.embed_model, [question])
        embed_ms = elapsed_ms(started)

        started = time.perf_counter()
        hits = await asyncio.to_thread(self._index.query, vector, self._settings.retrieval_k)
        retrieve_ms = elapsed_ms(started)

        started = time.perf_counter()
        generation = await self._ollama.generate(
            self._settings.chat_model, build_prompt(question, hits),
            self._settings.llm_seed, self._settings.max_answer_tokens)
        generate_ms = elapsed_ms(started)

        result = ChatOut(
            request_id=request_id,
            answer=generation.text,
            model=generation.model,
            prompt_version=PROMPT_VERSION,
            done_reason=generation.done_reason,
            sources=[ChatSource(product_id=h.product_id, name=h.name, distance=round(h.distance, 4)) for h in hits],
            tokens=ChatTokens(prompt=generation.prompt_tokens, completion=generation.completion_tokens),
            timings=ChatTimings(embed_ms=embed_ms, retrieve_ms=retrieve_ms, generate_ms=generate_ms,
                                total_ms=elapsed_ms(total_started)),
        )
        self._record(question, result)
        log.info("event=ai.chat request_id=%s model=%s prompt=%s sources=%s done_reason=%s total_ms=%.1f",
                 request_id, result.model, PROMPT_VERSION, [s.product_id for s in result.sources],
                 result.done_reason, result.timings.total_ms)
        return result

    def _record(self, question: str, result: ChatOut) -> None:
        """Append one JSON line per answer, so a wrong answer can be traced to its inputs later."""
        path: Path = self._settings.chat_log
        path.parent.mkdir(parents=True, exist_ok=True)
        entry = {"at": datetime.now(timezone.utc).isoformat(), "question": question, **result.model_dump()}
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry) + "\n")
EOF

# ── app/schemas_ai.py ────────────────────────────────────────────
cat > "${LESSON_DIR}/app/schemas_ai.py" << 'EOF'
"""Request and response models for the AI routes; they become part of the OpenAPI spec."""
from typing import Literal

from pydantic import BaseModel, Field


class ChatIn(BaseModel):
    """A customer question."""

    question: str = Field(min_length=1, max_length=500)


class ChatSource(BaseModel):
    """One product the answer was allowed to use, with its cosine distance to the question."""

    product_id: int
    name: str
    distance: float


class ChatTokens(BaseModel):
    """Token counts reported by Ollama."""

    prompt: int
    completion: int


class ChatTimings(BaseModel):
    """Milliseconds spent in each stage of the pipeline."""

    embed_ms: float
    retrieve_ms: float
    generate_ms: float
    total_ms: float


class ChatOut(BaseModel):
    """An answer plus the evidence needed to test it."""

    request_id: str
    answer: str
    model: str
    prompt_version: str
    done_reason: str
    sources: list[ChatSource]
    tokens: ChatTokens
    timings: ChatTimings


class ReindexOut(BaseModel):
    """Result of rebuilding the product index."""

    indexed: int
    collection: str
    embed_model: str


class AiStatusOut(BaseModel):
    """Whether the AI layer can answer right now, and if not, why."""

    ready: bool
    ollama: Literal["connected", "unreachable"]
    chroma: Literal["connected", "unreachable"]
    models_present: list[str]
    models_missing: list[str]
    indexed: int
EOF

# ── app/routers/ai.py ────────────────────────────────────────────
cat > "${LESSON_DIR}/app/routers/ai.py" << 'EOF'
"""AI routes: /chat, /ai/reindex, /ai/status."""
import asyncio

import asyncpg
from fastapi import APIRouter, Depends, HTTPException, Request, status

from app.ai.ollama import OllamaError, OllamaTimeout
from app.ai.service import ChatService
from app.config import settings
from app.db import get_pool
from app.schemas import Message
from app.schemas_ai import AiStatusOut, ChatIn, ChatOut, ReindexOut

router = APIRouter(tags=["ai"])


def get_chat(request: Request) -> ChatService:
    """Return the chat service stored on application state."""
    return request.app.state.chat


@router.post("/chat", response_model=ChatOut,
             responses={503: {"model": Message}, 504: {"model": Message}})
async def chat(body: ChatIn, service: ChatService = Depends(get_chat)) -> ChatOut:
    """Answer a product question from the indexed catalogue."""
    try:
        return await service.answer(body.question)
    except OllamaTimeout as exc:
        raise HTTPException(status.HTTP_504_GATEWAY_TIMEOUT, str(exc)) from exc
    except OllamaError as exc:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, f"vector store unavailable: {exc}") from exc


@router.post("/ai/reindex", response_model=ReindexOut, responses={503: {"model": Message}})
async def reindex(service: ChatService = Depends(get_chat),
                  pool: asyncpg.Pool = Depends(get_pool)) -> ReindexOut:
    """Re-embed every product and replace the Chroma collection."""
    try:
        count = await service.reindex(pool)
    except OllamaError as exc:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, f"vector store unavailable: {exc}") from exc
    return ReindexOut(indexed=count, collection=settings.chroma_collection, embed_model=settings.embed_model)


@router.get("/ai/status", response_model=AiStatusOut)
async def ai_status(service: ChatService = Depends(get_chat)) -> AiStatusOut:
    """Report models, vector store and index size; always 200 so it can be read while broken."""
    try:
        present = await service.ollama.models()
        ollama_state = "connected"
    except OllamaError:
        present, ollama_state = [], "unreachable"
    chroma_up = await asyncio.to_thread(service.index.heartbeat)
    indexed = await asyncio.to_thread(service.index.count) if chroma_up else 0
    wanted = [settings.chat_model, settings.embed_model]
    # Ollama lists "nomic-embed-text:latest" for a pull of "nomic-embed-text"
    missing = [m for m in wanted if m not in present and f"{m}:latest" not in present]
    return AiStatusOut(
        ready=ollama_state == "connected" and chroma_up and not missing and indexed > 0,
        ollama=ollama_state,
        chroma="connected" if chroma_up else "unreachable",
        models_present=sorted(present),
        models_missing=missing,
        indexed=indexed,
    )
EOF

# ── app/main.py ──────────────────────────────────────────────────
cat > "${LESSON_DIR}/app/main.py" << 'EOF'
"""Application factory, lifespan wiring, and the dependency-aware health route."""
import asyncio
import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import asyncpg
from fastapi import FastAPI, Request, Response, status
from fastapi.routing import APIRoute
from redis.asyncio import Redis

from app.ai.ollama import OllamaClient
from app.ai.service import ChatService
from app.ai.vectors import ProductIndex
from app.config import settings
from app.db import create_pool, create_redis, init_schema
from app.routers import ai, auth, orders, products
from app.schemas import HealthOut

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("qatp.ai")


def operation_id(route: APIRoute) -> str:
    """Use the function name as the operationId so it survives path renames."""
    return route.name


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Open every client on startup, index products once, and close everything on shutdown."""
    app.state.pool = await create_pool()
    app.state.redis = create_redis()
    await init_schema(app.state.pool)
    ollama = OllamaClient(settings.ollama_url, settings.llm_timeout_seconds, settings.ollama_keep_alive)
    index = ProductIndex(settings.chroma_host, settings.chroma_port, settings.chroma_collection)
    app.state.chat = ChatService(settings, ollama, index)
    try:
        await app.state.chat.reindex(app.state.pool)
    except Exception as exc:
        # Startup must not depend on the AI layer; /ai/status reports what is missing and /ai/reindex retries
        log.warning("event=ai.reindex_skipped reason=%s", exc)
    yield
    await ollama.aclose()
    await app.state.pool.close()
    await app.state.redis.aclose()


app = FastAPI(
    title="QATP-App",
    version="0.3.0",
    description="Application under test for the Testing What AI Builds course.",
    lifespan=lifespan,
    generate_unique_id_function=operation_id,
)
app.include_router(auth.router)
app.include_router(products.router)
app.include_router(orders.router)
app.include_router(ai.router)


async def check_db(pool: asyncpg.Pool) -> str:
    """Return 'connected' if Postgres answers a trivial query within two seconds."""
    try:
        await asyncio.wait_for(pool.fetchval("SELECT 1"), timeout=2)
    except Exception:
        return "unreachable"
    return "connected"


async def check_redis(redis: Redis) -> str:
    """Return 'connected' if Redis answers PING within two seconds."""
    try:
        await asyncio.wait_for(redis.ping(), timeout=2)
    except Exception:
        return "unreachable"
    return "connected"


@app.get(
    "/health",
    response_model=HealthOut,
    responses={503: {"model": HealthOut}},
    tags=["ops"],
)
async def health(request: Request, response: Response) -> HealthOut:
    """Report 200 only when both Postgres and Redis answer."""
    db_state = await check_db(request.app.state.pool)
    redis_state = await check_redis(request.app.state.redis)
    healthy = db_state == "connected" and redis_state == "connected"
    if not healthy:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
    return HealthOut(
        status="ok" if healthy else "degraded", db=db_state, redis=redis_state
    )
EOF

# ── tests/test_ai.py ─────────────────────────────────────────────
cat > "${LESSON_DIR}/tests/test_ai.py" << 'EOF'
"""Tests for the AI layer. They check structure and evidence, never the exact wording of an answer."""
import json
import os
from collections.abc import Iterator
from pathlib import Path

import httpx
import pytest

BASE_URL = os.getenv("QATP_BASE_URL", "http://localhost:8000")
CHAT_LOG = Path(os.getenv("CHAT_LOG", "reports/chat_log.jsonl"))


@pytest.fixture(scope="module")
def client() -> Iterator[httpx.Client]:
    """Yield a client with a timeout long enough for CPU inference."""
    with httpx.Client(base_url=BASE_URL, timeout=180) as http:
        yield http


@pytest.fixture(scope="module")
def keyboard_answer(client: httpx.Client) -> dict[str, object]:
    """Ask one question once and share the answer between tests, because each call costs seconds."""
    response = client.post("/chat", json={"question": "Do you sell a mechanical keyboard, and how much is it?"})
    assert response.status_code == 200, response.text
    return response.json()


def test_ai_layer_reports_ready(client: httpx.Client) -> None:
    """Both models are pulled, Chroma answers, and every product is indexed."""
    body = client.get("/ai/status").json()
    product_count = len(client.get("/products", params={"limit": 100}).json())
    assert body["ready"] is True, body
    assert body["models_missing"] == []
    assert body["indexed"] == product_count


def test_answer_names_its_model_and_prompt(keyboard_answer: dict[str, object]) -> None:
    """Every answer says which model and which prompt version produced it."""
    assert keyboard_answer["model"].startswith("llama3.2:3b")
    assert keyboard_answer["prompt_version"] == "shop-assistant-v1"
    assert keyboard_answer["answer"].strip() != ""


def test_answer_was_not_cut_off(keyboard_answer: dict[str, object]) -> None:
    """done_reason 'length' means the token cap truncated the answer, which reads fine but is incomplete."""
    assert keyboard_answer["done_reason"] == "stop"
    assert keyboard_answer["tokens"]["completion"] > 0


def test_sources_are_real_products_closest_first(client: httpx.Client, keyboard_answer: dict[str, object]) -> None:
    """Retrieved sources exist in the catalogue, are sorted by distance, and the keyboard ranks first."""
    sources = keyboard_answer["sources"]
    catalogue = {p["id"] for p in client.get("/products", params={"limit": 100}).json()}
    assert 1 <= len(sources) <= 3
    assert {s["product_id"] for s in sources} <= catalogue
    assert [s["distance"] for s in sources] == sorted(s["distance"] for s in sources)
    assert "Keyboard" in sources[0]["name"]


def test_same_question_retrieves_the_same_sources(client: httpx.Client, keyboard_answer: dict[str, object]) -> None:
    """Retrieval is repeatable even where generation is not, so it is the part to pin."""
    again = client.post("/chat", json={"question": "Do you sell a mechanical keyboard, and how much is it?"}).json()
    assert [s["product_id"] for s in again["sources"]] == [s["product_id"] for s in keyboard_answer["sources"]]


def test_every_answer_is_in_the_chat_log(keyboard_answer: dict[str, object]) -> None:
    """The chat log holds the request id with its sources, so a bad answer can be traced afterwards."""
    entries = [json.loads(line) for line in CHAT_LOG.read_text(encoding="utf-8").splitlines()]
    logged = [e for e in entries if e["request_id"] == keyboard_answer["request_id"]]
    assert len(logged) == 1
    assert logged[0]["sources"] == keyboard_answer["sources"]


def test_empty_question_is_rejected_before_the_model_runs(client: httpx.Client) -> None:
    """Validation happens in FastAPI, so an empty question costs nothing."""
    assert client.post("/chat", json={"question": ""}).status_code == 422


def test_spec_documents_the_ai_routes(client: httpx.Client) -> None:
    """The three AI operations are in the spec with stable ids and declared error responses."""
    paths = client.get("/openapi.json").json()["paths"]
    assert paths["/chat"]["post"]["operationId"] == "chat"
    assert {"200", "422", "503", "504"} <= set(paths["/chat"]["post"]["responses"])
    assert paths["/ai/status"]["get"]["operationId"] == "ai_status"
EOF

# ── Makefile ─────────────────────────────────────────────────────
cat > "${LESSON_DIR}/Makefile" << 'EOF'
# Recipes use ">" instead of a tab so copy-paste never breaks them
.RECIPEPREFIX := >
.PHONY: up down logs health status ask reindex pull test spec clean
Q ?= Do you sell a mechanical keyboard?

up:
> docker compose up -d --build --wait

down:
> docker compose down

logs:
> docker compose logs -f api

health:
> curl -s localhost:8000/health | python3 -m json.tool

status:
> curl -s localhost:8000/ai/status | python3 -m json.tool

ask:
> curl -s -X POST localhost:8000/chat -H 'Content-Type: application/json' -d '{"question":"$(Q)"}' | python3 -m json.tool

reindex:
> curl -s -X POST localhost:8000/ai/reindex | python3 -m json.tool

pull:
> @echo "Using host Ollama at http://192.168.1.13:11434 (LAPTOP-RVRF49B4); ensure llama3.2:3b and nomic-embed-text are pulled there."

test:
> docker compose exec -T api pytest tests -v

spec:
> curl -s localhost:8000/openapi.json -o reports/openapi.json
> @echo "Wrote reports/openapi.json"

clean:
> docker compose down -v
> rm -f reports/*.json reports/*.jsonl reports/*.txt
EOF

# ── README.md ────────────────────────────────────────────────────
cat > "${LESSON_DIR}/README.md" << 'EOF'
# Lesson 03 — QATP-App: The AI Layer

The Lesson 2 backend plus a retrieval-augmented `/chat` route: Ollama embeds the
question with nomic-embed-text, Chroma finds the three nearest products, and
llama3.2:3b answers from them. Every answer returns its evidence: model,
prompt version, sources with distances, token counts, done_reason and timings.

| Route            | What it does                                              |
|------------------|-----------------------------------------------------------|
| POST /chat       | Answer a product question; 503 if Ollama or Chroma is down |
| POST /ai/reindex | Re-embed every product into Chroma                         |
| GET /ai/status   | Models present, Chroma reachable, products indexed         |

Needs about 6 GB of free RAM and 3 GB of disk for the models. The first `up`
downloads them once into the `ollama-models` volume.

## Run

    make up        # first run pulls llama3.2:3b and nomic-embed-text
    make status    # "ready": true
    make ask Q="Which product has a privacy shutter?"
    make test      # 16 passed (8 from Lesson 2, 8 new)
    make down

Every answer is appended to reports/chat_log.jsonl.
EOF

echo -e "${GREEN}✓${RESET} Wrote the AI layer, tests, Makefile, and README"

# ── run_test: exercise the primary deliverable ───────────────────
run_test() {
  echo -e "\n${BOLD}${CYAN}▶ run_test: starting the stack (using host Ollama at http://LAPTOP-RVRF49B4:11434)${RESET}"
  if ! curl -fsS -m 5 http://LAPTOP-RVRF49B4:11434/api/tags > /dev/null 2>&1; then
    echo -e "❌ FAILED — host Ollama not reachable at http://LAPTOP-RVRF49B4:11434"
    return 1
  fi
  if curl -fs localhost:8000/health > /dev/null 2>&1 && ! "${COMPOSE[@]}" ps --status running api 2>/dev/null | grep -q api; then
    echo -e "❌ FAILED — port 8000 is taken, probably by Lesson 2. Run: make -C ${PREV_DIR} down"
    return 1
  fi
  if ! "${COMPOSE[@]}" up -d --build; then
    echo -e "❌ FAILED — docker compose could not start the stack"
    return 1
  fi

  local ready=0
  for _ in $(seq 1 180); do
    if curl -fsS localhost:8000/ai/status -o "${LESSON_DIR}/reports/ai_status.json" 2>/dev/null \
       && grep -q '"ready":true' "${LESSON_DIR}/reports/ai_status.json"; then
      ready=1
      break
    fi
    # The index is built at startup; if Ollama finished pulling after that, build it now
    curl -fs -X POST localhost:8000/ai/reindex > /dev/null 2>&1 || true
    sleep 5
  done
  if [[ "${ready}" -ne 1 ]]; then
    echo -e "❌ FAILED — /ai/status never reported ready within 15 minutes; see reports/ai_status.json"
    return 1
  fi

  curl -fsS -X POST localhost:8000/chat -H "Content-Type: application/json" \
    -d '{"question":"Which product has a privacy shutter, and what does it cost?"}' \
    -o "${LESSON_DIR}/reports/chat_sample.json"

  curl -fsS localhost:8000/openapi.json \
    | python3 -c "import json,sys; print(sum(len(m) for m in json.load(sys.stdin)['paths'].values()))" \
    > "${LESSON_DIR}/reports/endpoint_count.txt"

  if "${COMPOSE[@]}" exec -T api pytest tests -q > "${LESSON_DIR}/reports/pytest.txt" 2>&1; then
    echo -e "${GREEN}✅ PASSED${RESET} — the AI layer answers with evidence and all tests are green"
    return 0
  fi
  tail -n 25 "${LESSON_DIR}/reports/pytest.txt"
  echo -e "❌ FAILED — tests failed; see ${LESSON_DIR}/reports/pytest.txt"
  return 1
}

# ── verify_result: check what run_test left on disk ──────────────
verify_result() {
  local failures=0
  local reports="${LESSON_DIR}/reports"

  if grep -q '"ready":true' "${reports}/ai_status.json" 2>/dev/null; then
    echo -e "  ${GREEN}✓${RESET} ai_status.json reports ready"
  else
    echo -e "  ${YELLOW}✗${RESET} ai_status.json missing or not ready"
    failures=$((failures + 1))
  fi

  if python3 - "${reports}/chat_sample.json" << 'PY'
import json, sys
from pathlib import Path
body = json.loads(Path(sys.argv[1]).read_text())
assert body["answer"] and body["sources"] and body["prompt_version"] == "shop-assistant-v1"
assert body["model"].startswith("llama3.2:3b") and body["tokens"]["completion"] > 0
PY
  then
    echo -e "  ${GREEN}✓${RESET} chat_sample.json has an answer, sources, model and prompt version"
  else
    echo -e "  ${YELLOW}✗${RESET} chat_sample.json is missing evidence fields"
    failures=$((failures + 1))
  fi

  if [[ "$(tr -d '[:space:]' < "${reports}/endpoint_count.txt" 2>/dev/null)" == "20" ]]; then
    echo -e "  ${GREEN}✓${RESET} openapi.json lists 20 operations"
  else
    echo -e "  ${YELLOW}✗${RESET} endpoint_count.txt is not 20"
    failures=$((failures + 1))
  fi

  if [[ -s "${reports}/chat_log.jsonl" ]]; then
    echo -e "  ${GREEN}✓${RESET} chat_log.jsonl has $(wc -l < "${reports}/chat_log.jsonl" | tr -d ' ') logged answers"
  else
    echo -e "  ${YELLOW}✗${RESET} chat_log.jsonl is missing or empty"
    failures=$((failures + 1))
  fi

  if grep -Eq '[0-9]+ passed' "${reports}/pytest.txt" 2>/dev/null \
     && ! grep -Eq '[0-9]+ (failed|error)' "${reports}/pytest.txt"; then
    echo -e "  ${GREEN}✓${RESET} pytest.txt reports all tests passed"
  else
    echo -e "  ${YELLOW}✗${RESET} pytest.txt reports failures or is missing"
    failures=$((failures + 1))
  fi

  if [[ "${failures}" -eq 0 ]]; then
    echo -e "${BOLD}${GREEN}VERDICT: Lesson 03 AI layer verified — 5/5 checks passed${RESET}"
    return 0
  fi
  echo -e "${BOLD}${YELLOW}VERDICT: Lesson 03 incomplete — ${failures} check(s) failed${RESET}"
  return 1
}

# ── Execute ──────────────────────────────────────────────────────
if [[ "${1:-}" == "--no-run" ]]; then
  echo -e "${YELLOW}Skipped run_test (--no-run). Files are in ${LESSON_DIR}/.${RESET}"
elif ! command -v docker > /dev/null 2>&1; then
  echo -e "${YELLOW}Docker not found on PATH. Files are written; install Docker, then rerun.${RESET}"
else
  if run_test; then
    verify_result || true
  else
    echo -e "${YELLOW}run_test failed. Inspect: docker compose -f ${LESSON_DIR}/docker-compose.yml logs api${RESET}"
  fi
fi

# ── Next steps ───────────────────────────────────────────────────
echo -e "\n${BOLD}${CYAN}NEXT STEPS${RESET}"
echo -e "${BOLD}1.${RESET} Check the AI layer is ready:"
echo -e "     ${CYAN}curl -s localhost:8000/ai/status | python3 -m json.tool${RESET}"
echo -e "     Expected: \"ready\": true, \"models_missing\": [], \"indexed\": 5"
echo -e "${BOLD}2.${RESET} Ask a question:"
echo -e "     ${CYAN}curl -s -X POST localhost:8000/chat -H 'Content-Type: application/json' -d '{\"question\":\"Do you sell a mechanical keyboard?\"}' | python3 -m json.tool${RESET}"
echo -e "     Expected: \"sources\": [{\"name\": \"Mechanical Keyboard\", ...}], \"model\": \"llama3.2:3b\", \"done_reason\": \"stop\""
echo -e "${BOLD}3.${RESET} Open Swagger UI and find the ai group:"
echo -e "     ${CYAN}http://localhost:8000/docs${RESET}"
echo -e "     Expected: 20 operations, with POST /chat, POST /ai/reindex, GET /ai/status under \"ai\""
echo -e "${BOLD}4.${RESET} Read the evidence trail:"
echo -e "     ${CYAN}tail -n 1 ${LESSON_DIR}/reports/chat_log.jsonl | python3 -m json.tool${RESET}"
echo -e "     Expected: the question, request_id, sources and timings of the last answer"
echo -e "${BOLD}5.${RESET} Run the tests:"
echo -e "     ${CYAN}cd ${LESSON_DIR} && make test${RESET}"
echo -e "     Expected: 16 passed"