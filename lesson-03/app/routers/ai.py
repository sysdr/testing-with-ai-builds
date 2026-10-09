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
