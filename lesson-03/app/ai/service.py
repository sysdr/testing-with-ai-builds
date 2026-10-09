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
